#!/usr/bin/env node
/**
 * The standalone Agent SDK server — the no-VS-Code half of
 * `tom_core_agentic`'s Agent SDK transports.
 *
 * It speaks the **CLI server's existing wire**, unchanged: JSON-RPC 2.0
 * messages in 4-byte-big-endian-length-prefixed frames over a loopback TCP
 * socket. Speaking the existing protocol rather than inventing a narrow one is
 * what makes the hosted path testable without touching the VS Code extension,
 * and what makes "the same interface" literal.
 *
 * It implements only the methods the Anthropic binding needs:
 *
 *  - `agentSdk.queryVce` {streamId, prompt, options} -> {success, streamId}
 *  - `agentSdk.cancelVce` {streamId} -> {success}
 *  - `agentSdk.chunk` (notification, server->client)
 *  - `agentSdk.toolCall` (request, server->client)
 *  {streamId, server, tool, args} -> CallToolResult
 *
 * and nothing else. There is no `workspace.*`, no `tom_todo.*`, no
 * `executeExpressionVcb`. An app's AI button has no business
 * reaching any of them, and a surface that does not exist cannot be misused.
 *
 * ## Tools
 *
 * `agentSdk.toolCall` is the one reverse request, and it is the VS Code
 * extension's own (`AgentSdkBridge`, the Dart-defined tools of
 * `tom_vscode_scripting_api`), so both transports carry a tool call the same
 * way. A query whose `options.mcpServers` holds `{type:'sdk'}` *descriptors*
 * (name, version, and each tool's name, description and JSON Schema) has each
 * one rebuilt here into a real `createSdkMcpServer`. Every tool's handler
 * sends `agentSdk.toolCall` back over **the socket the query arrived on** and
 * awaits the client's JSON-RPC answer — the `CallToolResult` the Dart
 * app's tool binding produced. No new socket, port or pipe:
 * the tools run in the app, this process only relays.
 *
 * Such a query gets the SDK's own tools switched off here, whatever the caller
 * sent: `tools: []`, `allowedTools` exactly the relayed MCP tools, and
 * `strictMcpConfig`, so no file, shell or user-configured MCP tool can be
 * reached through the app.
 *
 * ## Lifecycle
 *
 * Started by `StandaloneNodeAiTransport`, never by a user. It binds an
 * ephemeral loopback port, announces it on stdout as
 * `AGENT_SDK_SERVER_READY {"port":NNNNN}`, and exits when its stdin closes —
 * so if the app dies, this dies with it rather than lingering with a
 * credential in memory.
 *
 * ## Security posture
 *
 * The socket is loopback-only and, unlike the VS Code CLI server, it accepts
 * **one client**: once the app connects, further connections are refused.
 * The window in which another local process could reach it is therefore the
 * few milliseconds between bind and the app's own connect. That is a real
 * boundary but a modest one, and it is stated rather than implied: any process
 * running as this user could in principle race for it.
 *
 * The Anthropic credential arrives in `process.env.ANTHROPIC_API_KEY`, is
 * passed to the Agent SDK, and is never logged, never echoed, and never sent
 * to a client.
 */

'use strict';

const net = require('net');

/** The notification method every chunk is sent under (mirrors the extension). */
const CHUNK_METHOD = 'agentSdk.chunk';

/** The stdout line the Dart side waits for. */
const READY_PREFIX = 'AGENT_SDK_SERVER_READY ';

/** The reverse request a relayed tool handler is invoked over (mirrors the extension). */
const TOOL_CALL_METHOD = 'agentSdk.toolCall';

/** Live queries by streamId, so `agentSdk.cancelVce` can abort them. */
const controllers = new Map();

/**
 * Reverse requests awaiting the client's answer, by JSON-RPC id:
 * `{ streamId, resolve, reject }`. Rejected when their query is aborted or the
 * socket closes, so a tool handler never waits on a client that has gone.
 */
const pendingRequests = new Map();
let nextRequestId = 1;

/** Lazily-loaded, ESM-only Agent SDK. */
let sdkPromise = null;
function loadSdk() {
    if (!sdkPromise) {
        sdkPromise = import('@anthropic-ai/claude-agent-sdk');
    }
    return sdkPromise;
}

// ---------------------------------------------------------------------------
// Framing: 4-byte big-endian length prefix + UTF-8 JSON payload.
// ---------------------------------------------------------------------------

function writeMessage(socket, message) {
    const payload = Buffer.from(JSON.stringify(message), 'utf8');
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32BE(payload.length, 0);
    socket.write(Buffer.concat([header, payload]));
}

/**
 * Accumulates socket data and yields whole frames. Kept as a closure over one
 * buffer rather than a class: there is exactly one client, and one buffer.
 */
function createFrameReader(onMessage, onProtocolError) {
    let buffer = Buffer.alloc(0);
    return (chunk) => {
        buffer = Buffer.concat([buffer, chunk]);
        for (;;) {
            if (buffer.length < 4) return;
            const length = buffer.readUInt32BE(0);
            if (buffer.length < 4 + length) return;
            const payload = buffer.subarray(4, 4 + length);
            buffer = buffer.subarray(4 + length);
            try {
                onMessage(JSON.parse(payload.toString('utf8')));
            } catch (err) {
                onProtocolError(err);
            }
        }
    };
}

// ---------------------------------------------------------------------------
// The client -> server methods and the chunk notification.
// ---------------------------------------------------------------------------

function sendChunk(socket, params) {
    writeMessage(socket, { jsonrpc: '2.0', method: CHUNK_METHOD, params });
}

// ---------------------------------------------------------------------------
// The reverse request: a tool call answered by the client.
// ---------------------------------------------------------------------------

/**
 * Sends [method] to the client over [socket] and resolves with its answer.
 * Settled by `handleReply`; rejected by `rejectPending` when the query is
 * aborted or the socket closes.
 */
function requestClient(socket, streamId, method, params) {
    const id = `agent-sdk-srv-${nextRequestId++}`;
    return new Promise((resolve, reject) => {
        pendingRequests.set(id, { streamId, resolve, reject });
        try {
            writeMessage(socket, { jsonrpc: '2.0', id, method, params });
        } catch (err) {
            pendingRequests.delete(id);
            reject(err);
        }
    });
}

/** Settles the pending request a client reply answers. Unknown ids are dropped. */
function handleReply(message) {
    const pending = pendingRequests.get(message.id);
    if (!pending) return;
    pendingRequests.delete(message.id);
    if (message.error) {
        const text =
            message.error && message.error.message
                ? message.error.message
                : JSON.stringify(message.error);
        pending.reject(new Error(text));
    } else {
        pending.resolve(message.result);
    }
}

/** Rejects every pending request — of [streamId], or all when it is null. */
function rejectPending(streamId, reason) {
    for (const [id, pending] of pendingRequests) {
        if (streamId === null || pending.streamId === streamId) {
            pendingRequests.delete(id);
            pending.reject(new Error(reason));
        }
    }
}

/**
 * JSON Schema -> Zod raw shape, the subset the relayed tools declare (string,
 * integer, number, boolean, array, object, string enums). The same mechanical
 * conversion as the VS Code extension's `toRawShape`, so a tool reads the same
 * to the model over either transport. Anything else becomes `unknown` and is
 * validated where the tool runs — by the registry, before any document access.
 */
function toRawShape(z, schema) {
    function property(prop) {
        if (!prop || typeof prop !== 'object') return z.unknown();
        const values = Array.isArray(prop.enum)
            ? prop.enum.filter((v) => typeof v === 'string')
            : [];
        if (values.length > 0) return z.enum(values);
        switch (prop.type) {
            case 'string':
                return z.string();
            case 'integer':
                return z.number().int();
            case 'number':
                return z.number();
            case 'boolean':
                return z.boolean();
            case 'array':
                return z.array(prop.items ? property(prop.items) : z.unknown());
            case 'object':
                return z.record(z.string(), z.unknown());
            default:
                return z.unknown();
        }
    }
    const shape = {};
    const properties = (schema && schema.properties) || {};
    const required = new Set(Array.isArray(schema && schema.required) ? schema.required : []);
    for (const [name, prop] of Object.entries(properties)) {
        let type = property(prop);
        if (prop && typeof prop.description === 'string' && prop.description) {
            type = type.describe(prop.description);
        }
        shape[name] = required.has(name) ? type : type.optional();
    }
    return shape;
}

/**
 * Rebuilds the `{type:'sdk'}` descriptors in [mcpServers] into real in-process
 * MCP servers whose handlers relay to the client. Returns the rebuilt map and
 * the `mcp__<server>__<tool>` names it declares; null when there are none.
 */
async function buildToolServers(sdk, socket, streamId, mcpServers) {
    const entries = Object.entries(mcpServers || {}).filter(
        ([, value]) => value && typeof value === 'object' && value.type === 'sdk',
    );
    if (entries.length === 0) return null;
    // `zod` is the Agent SDK's declared peer, installed beside it (the
    // packaging suite checks it is present), and the one `tool` expects.
    const z = (await import('zod')).z;
    const servers = {};
    const toolNames = [];
    for (const [serverName, descriptor] of entries) {
        const tools = (descriptor.tools || []).map((t) => {
            toolNames.push(`mcp__${serverName}__${t.name}`);
            return sdk.tool(
                t.name,
                t.description || '',
                toRawShape(z, t.inputSchema || {}),
                (args) =>
                    requestClient(socket, streamId, TOOL_CALL_METHOD, {
                        streamId,
                        server: serverName,
                        tool: t.name,
                        args: args || {},
                    }),
            );
        });
        servers[serverName] = sdk.createSdkMcpServer({
            name: descriptor.name || serverName,
            version: descriptor.version || '1.0.0',
            // Declared up front rather than deferred behind tool search: with
            // the SDK's own tools off there is no tool search to find them.
            alwaysLoad: true,
            tools,
        });
    }
    return { servers, toolNames };
}

async function startQuery(socket, params) {
    const { streamId, prompt } = params;
    const callerOptions = params.options || {};

    const abortController = new AbortController();
    controllers.set(streamId, abortController);

    let sdk;
    try {
        sdk = await loadSdk();
    } catch (err) {
        // A missing SDK is the single most likely deployment failure, so it
        // gets a message that says what to do rather than a module trace.
        sendChunk(socket, {
            streamId,
            error:
                'The Claude Agent SDK is not installed for the standalone AI ' +
                'server. Run `npm install` in the server directory. (' +
                String(err && err.message ? err.message : err) +
                ')',
        });
        controllers.delete(streamId);
        return { success: true, streamId };
    }

    let stream;
    try {
        const options = { ...callerOptions, abortController };
        const relayed = await buildToolServers(sdk, socket, streamId, callerOptions.mcpServers);
        if (relayed) {
            // Only the relayed tools: no built-in file or shell tool,
            // no MCP server from the user's settings (see the file header).
            options.mcpServers = relayed.servers;
            options.tools = [];
            options.allowedTools = relayed.toolNames;
            options.strictMcpConfig = true;
        }
        stream = sdk.query({ prompt, options });
    } catch (err) {
        sendChunk(socket, { streamId, error: errorMessage(err) });
        controllers.delete(streamId);
        return { success: true, streamId };
    }

    // Detached pump, mirroring the extension bridge: the start request is
    // answered immediately and the messages arrive as notifications.
    void pump(socket, streamId, stream);
    return { success: true, streamId };
}

async function pump(socket, streamId, stream) {
    try {
        for await (const message of stream) {
            sendChunk(socket, { streamId, message });
        }
        sendChunk(socket, { streamId, done: true });
    } catch (err) {
        if (err && err.name === 'AbortError') {
            sendChunk(socket, { streamId, done: true });
        } else {
            sendChunk(socket, { streamId, error: errorMessage(err) });
        }
    } finally {
        controllers.delete(streamId);
        rejectPending(streamId, 'The query ended.');
    }
}

function cancelQuery(params) {
    const controller = controllers.get(params.streamId);
    if (controller) {
        controller.abort();
        controllers.delete(params.streamId);
    }
    rejectPending(params.streamId, 'The query was cancelled.');
    return { success: true };
}

function errorMessage(err) {
    return err instanceof Error ? err.message : String(err);
}

// ---------------------------------------------------------------------------
// Server.
// ---------------------------------------------------------------------------

function handleConnection(socket) {
    socket.on(
        'data',
        createFrameReader(
            async (message) => {
                const { id, method, params } = message;
                if (id === undefined) return; // a notification; we expect none
                if (method === undefined) {
                    // The client's answer to a reverse request (a tool call).
                    handleReply(message);
                    return;
                }
                try {
                    let result;
                    switch (method) {
                        case 'agentSdk.queryVce':
                            result = await startQuery(socket, params || {});
                            break;
                        case 'agentSdk.cancelVce':
                            result = cancelQuery(params || {});
                            break;
                        default:
                            writeMessage(socket, {
                                jsonrpc: '2.0',
                                id,
                                error: {
                                    code: -32601,
                                    message: `Method not found: ${method}`,
                                },
                            });
                            return;
                    }
                    writeMessage(socket, { jsonrpc: '2.0', id, result });
                } catch (err) {
                    writeMessage(socket, {
                        jsonrpc: '2.0',
                        id,
                        error: { code: -32000, message: errorMessage(err) },
                    });
                }
            },
            (err) => {
                process.stderr.write(`frame error: ${errorMessage(err)}\n`);
            },
        ),
    );

    socket.on('error', (err) => {
        process.stderr.write(`socket error: ${errorMessage(err)}\n`);
    });

    socket.on('close', () => {
        for (const controller of controllers.values()) controller.abort();
        controllers.clear();
        rejectPending(null, 'The client disconnected.');
    });
}

function main() {
    let clientConnected = false;

    const server = net.createServer((socket) => {
        if (clientConnected) {
            // One client only — see the security note at the top of the file.
            socket.destroy();
            return;
        }
        clientConnected = true;
        socket.on('close', () => {
            clientConnected = false;
        });
        handleConnection(socket);
    });

    server.on('error', (err) => {
        process.stderr.write(`server error: ${errorMessage(err)}\n`);
        process.exit(1);
    });

    // Port 0 = an ephemeral loopback port, so this never collides with the VS
    // Code CLI server's 19900–19909 range and both can run at once.
    server.listen(0, '127.0.0.1', () => {
        const { port } = server.address();
        process.stdout.write(`${READY_PREFIX}${JSON.stringify({ port })}\n`);
    });

    // The app's liveness channel: when the app exits, our stdin closes and we
    // go with it rather than lingering with a credential in memory.
    process.stdin.on('end', () => process.exit(0));
    process.stdin.on('close', () => process.exit(0));
    process.stdin.resume();
}

main();

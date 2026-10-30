#!/usr/bin/env node
// Lets Claude Desktop, which starts its tools as programs it talks to over stdin and stdout,
// use the server Bezzle runs inside itself. Each message is passed on to Bezzle as it is.
// While Bezzle is closed, the tools are listed from a copy Bezzle wrote beside this when it
// made the extension (ClaudeExtension.swift), and using one opens Bezzle.

const { execFile } = require("node:child_process");
const { readFileSync } = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const port = process.env.BEZZLE_MCP_PORT || "7412";
const address = `http://127.0.0.1:${port}/mcp`;
const bundleID = process.env.BEZZLE_BUNDLE_ID || "com.erik.Bezzle";
// As MCPServer speaks them.
const protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
const snapshot = JSON.parse(readFileSync(path.join(__dirname, "snapshot.json"), "utf8"));

const send = (message) => process.stdout.write(JSON.stringify(message) + "\n");
const answer = (id, result) => send({ jsonrpc: "2.0", id, result });
const failure = (id, code, message) => send({ jsonrpc: "2.0", id, error: { code, message } });
const toolError = (id, text) => answer(id, { content: [{ type: "text", text }], isError: true });
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const run = (file, args) => new Promise((done) => execFile(file, args, (error) => done(!error)));

class Unreachable extends Error {}

/** Bezzle's answer to `body`, or null when it has nothing to say (a notification). */
async function forward(body) {
    let response;
    try {
        response = await fetch(address, {
            method: "POST",
            headers: { "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
            body,
        });
    } catch {
        throw new Unreachable();
    }
    const text = await response.text();
    if (response.status === 202 || text.trim() === "") return null;
    if (!response.ok) throw new Error(`Bezzle answered ${response.status}: ${text.trim()}`);
    return JSON.parse(text);
}

/** Opens Bezzle if it isn't running, and waits for its server. False when it never answers. */
async function launch() {
    const running = await run("/usr/bin/pgrep", ["-x", "Bezzle"]);
    if (!running && !(await run("/usr/bin/open", ["-b", bundleID]))) return false;
    for (let waited = 0; waited < (running ? 3000 : 20000); waited += 250) {
        await sleep(250);
        try {
            await forward(JSON.stringify({ jsonrpc: "2.0", id: 0, method: "ping" }));
            return true;
        } catch (error) {
            if (!(error instanceof Unreachable)) return true;
        }
    }
    return false;
}

/** What to say for `message` while Bezzle is closed. */
async function offline(message, body) {
    const { id, method } = message;
    if (id === undefined) return;
    switch (method) {
        case "initialize": {
            const asked = message.params?.protocolVersion;
            const protocolVersion = protocolVersions.includes(asked) ? asked : snapshot.initialize.protocolVersion;
            return answer(id, { ...snapshot.initialize, protocolVersion });
        }
        case "ping":
            return answer(id, {});
        case "tools/list":
            return answer(id, { tools: snapshot.tools });
        case "tools/call":
            if (!(await launch())) {
                return toolError(id, "Bezzle didn't answer. Open Bezzle and check that Bezzle ▸ Allow AI Control is on, then try again.");
            }
            try {
                return send(await forward(body));
            } catch (error) {
                return toolError(id, `Bezzle didn't answer: ${error.message}`);
            }
        default:
            return failure(id, -32601, `Bezzle is closed, so it can't answer ${method}.`);
    }
}

async function handle(line) {
    if (line.trim() === "") return;
    let message;
    try {
        message = JSON.parse(line);
    } catch {
        return failure(null, -32700, "That wasn't JSON.");
    }
    try {
        const reply = await forward(line);
        if (reply) send(reply);
    } catch (error) {
        if (error instanceof Unreachable && !Array.isArray(message)) return offline(message, line);
        if (message.id !== undefined) failure(message.id, -32603, error.message);
    }
}

// One message at a time, so answers come back in the order they were asked.
let queue = Promise.resolve();
readline.createInterface({ input: process.stdin })
    .on("line", (line) => {
        queue = queue.then(() => handle(line)).catch((error) => process.stderr.write(`${error.stack}\n`));
    })
    .on("close", () => queue.then(() => process.exit(0)));

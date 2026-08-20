import { loadConfig } from "./config.js";
import { startServer } from "./server.js";

const config = loadConfig();
const { port } = await startServer(config);
const host = process.env.HOST ?? "127.0.0.1";
console.log(`xCover pricing agent listening on http://${host}:${port}`);

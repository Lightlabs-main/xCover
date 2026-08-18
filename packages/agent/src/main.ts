import { loadConfig } from "./config.js";
import { startServer } from "./server.js";

const config = loadConfig();
const { port } = await startServer(config);
console.log(`xCover pricing agent listening on http://127.0.0.1:${port}`);


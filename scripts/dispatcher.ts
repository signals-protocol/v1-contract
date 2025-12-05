import { normalizeEnvironment } from "./utils/environment";
import type { Environment } from "./types/environment";

function usage() {
  console.error("Usage: COMMAND=<action:env> hardhat run scripts/dispatcher.ts --network <network>");
  console.error("Actions: deploy, upgrade, safety-check, verify. Envs: localhost, citrea:dev, citrea:prod");
  process.exit(1);
}

async function main() {
  const command = process.env.COMMAND;
  if (!command) {
    usage();
    return;
  }
  const [action, ...envParts] = command.split(":");
  const env = normalizeEnvironment(envParts.join(":") || "localhost") as Environment;

  switch (action) {
    case "deploy": {
      const { deployAction } = await import("./actions/deploy-v1");
      await deployAction(env);
      break;
    }
    case "upgrade": {
      const { upgradeAction } = await import("./actions/upgrade-v1");
      await upgradeAction(env);
      break;
    }
    case "safety-check": {
      const { safetyCheckAction } = await import("./actions/safety-check");
      await safetyCheckAction(env);
      break;
    }
    case "verify": {
      const { verifyAction } = await import("./actions/verify-v1");
      await verifyAction(env);
      break;
    }
    default:
      usage();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

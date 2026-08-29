# CLAUDE.md

This project is managed by the dashboard's Crafting tab. To be startable and
previewable from the dashboard, this directory needs a `start.json` describing
how to launch it.

When the app is runnable (has a dev server / start command), use the **add-app**
skill to analyze this project and work out `startCommand`, `portsNeeded`, and
`frontendPort` (same rules as the dashboard's Apps: `{{PORT_1}}`, `{{PORT_2}}`
placeholders, always bind `0.0.0.0`, never `localhost`/`127.0.0.1`). Instead of
emitting a full AppConfig for the "Add App" drawer, write just those three
fields as `start.json` in this project's root:

```json
{ "startCommand": "npm run dev -- --port {{PORT_1}} --host 0.0.0.0", "portsNeeded": 1, "frontendPort": 1 }
```

Keep `start.json` in sync whenever the launch command changes.

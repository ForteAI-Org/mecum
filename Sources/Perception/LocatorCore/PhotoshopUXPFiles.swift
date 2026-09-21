import Foundation

/// The PHOTOSHOP twin of `UXPPluginFiles` — same inverted long-poll transport, Photoshop's modern DOM on
/// the other end. Photoshop is the app UXP serves best (first-class since 22): open documents, run real
/// filters via batchPlay descriptors, save renditions to explicit paths — all transaction-safe, all
/// impossible for vision to do as fast or as verifiably.
///
/// Verbs are a fixed vetted set, like Premiere's: UXP has no eval, and fixed verbs match the engine's
/// philosophy anyway. `localFileSystem: "fullAccess"` because ps_open/ps_save_as take REAL paths — the
/// whole point is driving files the agent already knows about ("plugin" scope would sandbox them away).
///
/// TRAP, paid for once: the manifest's host id is Adobe's short code — "PS", never "photoshop"
/// (Premiere's really is "premierepro"). Creative Cloud's installer answers a wrong id with
/// "error code -4", which its docs decode as a manifest parse failure and nothing on screen explains.
/// Our OWN host key for /uxp/pull stays "photoshop" — that string is ours, independent of Adobe's.
public enum PhotoshopUXPFiles {
    public static let pluginId = "com.forte.locator.uxp.ps"

    public static var installDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fflow/uxp/\(pluginId)", isDirectory: true)
    }

    public static let manifest = """
    {
      "manifestVersion": 5,
      "id": "\(pluginId)",
      "name": "Forte Locator UXP for Photoshop",
      "version": "1.0.0",
      "main": "index.html",
      "host": { "app": "PS", "minVersion": "23.0.0" },
      "entrypoints": [
        { "type": "panel", "id": "bridge",
          "label": { "default": "Forte Locator UXP" },
          "minimumSize": { "width": 220, "height": 100 } }
      ],
      "requiredPermissions": {
        "network": { "domains": "all" },
        "localFileSystem": "fullAccess"
      }
    }
    """

    public static let indexHTML = """
    <html><head><style>
    body{font-family:-apple-system,sans-serif;font-size:11px;background:#1e1e1e;color:#9fe6a0;margin:8px}
    b{color:#fff}
    </style></head>
    <body><div><b>Forte Locator UXP (Photoshop)</b></div><div id="s">starting…</div>
    <script src="main.js"></script></body></html>
    """

    public static let mainJS = """
    // Forte Locator UXP bridge (Photoshop) — long-polls the local engine for jobs, answers with DOM truth.
    const BASE = "http://127.0.0.1:4670";
    const ps = require("photoshop");
    const uxpfs = require("uxp").storage.localFileSystem;
    const el = document.getElementById("s");
    function show(t){ if (el) el.textContent = t; }

    // Every mutation runs inside executeAsModal — Photoshop refuses DOM writes outside it.
    async function modal(name, fn){
      let out;
      await ps.core.executeAsModal(async () => { out = await fn(); }, { commandName: name });
      return out;
    }

    // The filter menu, as batchPlay descriptors. Names are the agent-facing vocabulary; each entry is a
    // REAL Photoshop filter with a visible, demo-friendly effect and a sane default amount.
    function filterDescriptor(name, amount){
      switch (name) {
        case "gaussian_blur": return { _obj: "gaussianBlur", radius: { _unit: "pixelsUnit", _value: amount || 8 } };
        case "motion_blur":   return { _obj: "motionBlur", angle: 0, distance: { _unit: "pixelsUnit", _value: amount || 25 } };
        case "crystallize":   return { _obj: "crystallize", cellSize: amount || 14 };
        case "invert":        return { _obj: "invert" };
        case "sharpen":       return { _obj: "sharpen" };
        default: return null;
      }
    }

    const verbs = {
      ping: async () => ({ ok: true, pong: true, host: "photoshop" }),

      status: async () => {
        const d = ps.app.activeDocument;
        return { ok: true, document: d ? String(d.title || d.name) : null, documents: ps.app.documents.length };
      },

      new_document: async (a) => {
        const w = a.width || 1080, h = a.height || 1080;
        await modal("Locator: new document", async () => {
          await ps.app.createDocument({ width: w, height: h, resolution: a.resolution || 72,
                                        name: a.name || "Untitled", mode: "RGBColorMode", fill: "white" });
        });
        const d = ps.app.activeDocument;
        return { ok: true, created: String(d.title || d.name), width: w, height: h };
      },

      open: async (a) => {
        if (!a.path) return { ok: false, error: "need path" };
        const entry = await uxpfs.getEntryWithUrl("file:" + a.path);
        await modal("Locator: open", async () => { await ps.app.open(entry); });
        const d = ps.app.activeDocument;
        return { ok: true, opened: String(d.title || d.name), width: d.width, height: d.height };
      },

      apply_filter: async (a) => {
        const desc = filterDescriptor(String(a.filter || ""), a.amount);
        if (!desc) return { ok: false, error: "unknown filter '" + a.filter + "' — have: gaussian_blur, motion_blur, crystallize, invert, sharpen" };
        if (!ps.app.activeDocument) return { ok: false, error: "no open document — ps_open first" };
        const r = await modal("Locator: " + a.filter, async () =>
          await ps.action.batchPlay([desc], {}));
        const err = r && r[0] && r[0].message;
        return err ? { ok: false, error: String(err) } : { ok: true, applied: a.filter };
      },

      // File > Revert — back to the saved state, so three filters make three IMAGES, not one stack.
      revert: async () => {
        if (!ps.app.activeDocument) return { ok: false, error: "no open document" };
        await modal("Locator: revert", async () => await ps.action.batchPlay([{ _obj: "revert" }], {}));
        return { ok: true, reverted: true };
      },

      save_as: async (a) => {
        if (!a.path) return { ok: false, error: "need path (.png or .jpg)" };
        const d = ps.app.activeDocument;
        if (!d) return { ok: false, error: "no open document — ps_open first" };
        const entry = await uxpfs.createEntryWithUrl("file:" + a.path, { overwrite: true });
        const isJpg = /\\.jpe?g$/i.test(a.path);
        await modal("Locator: save as", async () => {
          if (isJpg) await d.saveAs.jpg(entry, { quality: a.quality || 10 }, true);
          else await d.saveAs.png(entry, {}, true);
        });
        return { ok: true, saved: a.path };
      },
    };

    async function loop(){
      show("polling engine at " + BASE + " …");
      for (;;) {
        try {
          const r = await fetch(BASE + "/uxp/pull", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ host: "photoshop" }),
          });
          if (r.status === 200) {
            const job = await r.json();
            let data;
            try {
              data = verbs[job.verb] ? await verbs[job.verb](job.args || {})
                                     : { ok: false, error: "unknown verb " + job.verb };
            } catch (e) { data = { ok: false, error: String((e && e.message) || e) }; }
            await fetch(BASE + "/uxp/result", {
              method: "POST", headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ id: job.id, data: data }),
            });
            show("last: " + job.verb + " ✓");
          }
        } catch (e) {
          show("engine offline — retrying… (" + e + ")");
          await new Promise((res) => setTimeout(res, 3000));
        }
      }
    }
    loop();
    """
}

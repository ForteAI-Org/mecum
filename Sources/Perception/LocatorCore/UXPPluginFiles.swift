import Foundation

/// The UXP plugin bundle, embedded so `locator uxp install-plugin` is self-contained (same pattern as
/// the CEP PremiereBridgeFiles). The plugin is the ENGINE'S HANDS inside Adobe's modern platform: it
/// long-polls the serve's /uxp/pull for jobs, runs a FIXED, vetted verb set against the UXP DOM
/// (ppro = require("premierepro")) and posts results back. No eval — UXP forbids it and the engine's
/// philosophy prefers vetted verbs anyway. Written against Adobe's own premierepro.d.ts (26.5-beta):
/// Sequence.getVideoTrack(i) → VideoTrack.getTrackItems(CLIP, false) → getComponentChain() →
/// Component.getDisplayName()/getParam(j).displayName → ComponentParam.createKeyframe +
/// createSetValueAction → project.executeTransaction(compound => compound.addAction(a)).
public enum UXPPluginFiles {
    public static let pluginId = "com.forte.locator.uxp"

    /// Where the plugin bundle is written for UDT to load.
    public static var installDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fflow/uxp/\(pluginId)", isDirectory: true)
    }

    /// manifest v5 (the documented dev shape; Premiere's own plugins use v6 but v5 is what UDT scaffolds).
    /// network.domains "all" so fetch to 127.0.0.1:4670 is permitted — the TARGET is still only our
    /// loopback server; the value just sidesteps undocumented localhost-allowlist behavior.
    public static let manifest = """
    {
      "manifestVersion": 5,
      "id": "\(pluginId)",
      "name": "Forte Locator UXP",
      "version": "1.0.0",
      "main": "index.html",
      "host": { "app": "premierepro", "minVersion": "25.0.0" },
      "entrypoints": [
        { "type": "panel", "id": "bridge",
          "label": { "default": "Forte Locator UXP" },
          "minimumSize": { "width": 220, "height": 100 } }
      ],
      "requiredPermissions": {
        "network": { "domains": "all" },
        "localFileSystem": "plugin"
      }
    }
    """

    public static let indexHTML = """
    <html><head><style>
    body{font-family:-apple-system,sans-serif;font-size:11px;background:#1e1e1e;color:#9fe6a0;margin:8px}
    b{color:#fff}
    </style></head>
    <body><div><b>Forte Locator UXP</b></div><div id="s">starting…</div>
    <script src="main.js"></script></body></html>
    """

    public static let mainJS = """
    // Forte Locator UXP bridge — long-polls the local engine for jobs, answers with UXP DOM truth.
    const BASE = "http://127.0.0.1:4670";
    const ppro = require("premierepro");
    const el = document.getElementById("s");
    function show(t){ if (el) el.textContent = t; }

    async function getClip(a){
      const proj = await ppro.Project.getActiveProject();
      if (!proj) throw new Error("no open project");
      const seq = await proj.getActiveSequence();
      if (!seq) throw new Error("no active sequence");
      const track = await seq.getVideoTrack((a.track || 1) - 1);
      if (!track) throw new Error("no video track V" + (a.track || 1));
      const items = await track.getTrackItems(ppro.Constants.TrackItemType.CLIP, false);
      const item = items[(a.clip || 1) - 1];
      if (!item) throw new Error("no clip " + (a.clip || 1) + " on V" + (a.track || 1) + " (" + items.length + " clips)");
      return { proj, item };
    }

    const verbs = {
      ping: async () => ({ ok: true, pong: true, host: "premierepro" }),

      status: async () => {
        const p = await ppro.Project.getActiveProject();
        return { ok: true, project: p ? String(await p.name) : null };
      },

      // Real components + parameter names per clip — discovery for set_param.
      get_params: async (a) => {
        const { item } = await getClip(a);
        const chain = await item.getComponentChain();
        const out = [];
        const n = chain.getComponentCount();
        for (let i = 0; i < n; i++) {
          const c = chain.getComponentAtIndex(i);
          const dn = String(await c.getDisplayName());
          const params = [];
          const pc = c.getParamCount();
          for (let j = 0; j < pc; j++) {
            const pj = c.getParam(j);
            let v = null;
            try {
              const kf = await pj.getStartValue();
              let raw = kf && kf.value !== undefined ? kf.value : null;
              if (raw && typeof raw === "object" && raw.value !== undefined) raw = raw.value;  // Keyframe.value is nested {value} (verified live)
              if (raw !== null && typeof raw !== "object") v = raw;
            } catch (e) {}
            params.push(String(pj.displayName) + (v !== null ? "=" + v : ""));
          }
          out.push({ component: dn, params: params });
        }
        return { ok: true, components: out };
      },

      // THE verb CEP/QE cannot do: set an effect parameter's value, transaction-safe (undoable).
      set_param: async (a) => {
        const { proj, item } = await getClip(a);
        const chain = await item.getComponentChain();
        const want = String(a.component || "").toLowerCase();
        const wantP = String(a.param || "").toLowerCase();
        const n = chain.getComponentCount();
        for (let i = 0; i < n; i++) {
          const c = chain.getComponentAtIndex(i);
          const dn = String(await c.getDisplayName());
          if (dn.toLowerCase() !== want) continue;
          const pc = c.getParamCount();
          const names = [];
          for (let j = 0; j < pc; j++) {
            const p = c.getParam(j);
            names.push(String(p.displayName));
            if (String(p.displayName).toLowerCase() !== wantP) continue;
            let done = false;
            // Keyframe + action MUST be created INSIDE the transaction callback — creating them outside
            // throws "The script object is no longer valid" (found live on PPro 26.3.2).
            proj.lockedAccess(() => {
              done = proj.executeTransaction((ca) => {
                const kf = p.createKeyframe(a.value);
                const act = p.createSetValueAction(kf, true);
                ca.addAction(act);
              }, "Locator: set " + p.displayName);
            });
            return { ok: done, set: done, component: dn, param: String(p.displayName), value: a.value };
          }
          return { ok: false, error: "no param '" + a.param + "' on " + dn + " — has: " + names.join(", ") };
        }
        return { ok: false, error: "no component '" + a.component + "' on this clip — get_params lists them" };
      },
    };

    async function loop(){
      show("polling engine at " + BASE + " …");
      for (;;) {
        try {
          const r = await fetch(BASE + "/uxp/pull", {
            method: "POST", headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ host: "premierepro" }),
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
          // 204 = engine held the poll 20s with no work — re-poll immediately.
        } catch (e) {
          show("engine offline — retrying… (" + e + ")");
          await new Promise((res) => setTimeout(res, 3000));
        }
      }
    }
    loop();
    """
}

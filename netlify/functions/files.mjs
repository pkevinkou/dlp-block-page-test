import { getStore } from "@netlify/blobs";

// 共用檔案區：無認證，任何人皆可上傳、下載、刪除。
// 單檔上限受 Netlify Functions 的 request body 限制（約 6 MB），此處保守設定。
const MAX_SIZE = 4_000_000;
const MAX_FILES = 50;

const H = { "content-type": "application/json; charset=utf-8" };
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: H });

export default async (req) => {
  // strong consistency：預設的 eventual 模式下，剛上傳的檔案不會立刻出現在 list()。
  let store;
  try { store = getStore({ name: "shared-files", consistency: "strong" }); }
  catch (e) { return json({ error: "store init: " + e.message }, 500); }

  const id = new URL(req.url).searchParams.get("id");

  try {
    if (req.method === "GET" && id) {
      const data = await store.get(id, { type: "arrayBuffer" });
      if (!data) return json({ error: "not_found" }, 404);
      const m = (await store.getMetadata(id))?.metadata || {};
      const name = m.name || id;
      return new Response(data, {
        headers: {
          "content-type": "application/octet-stream",
          "content-length": String(data.byteLength),
          "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(name)}`,
        },
      });
    }

    if (req.method === "GET") {
      const { blobs } = await store.list();
      const files = [];
      for (const b of blobs) {
        const m = (await store.getMetadata(b.key))?.metadata || {};
        files.push({
          id: b.key,
          name: m.name || b.key,
          size: m.size || 0,
          uploadedAt: m.uploadedAt || "",
        });
      }
      files.sort((a, b) => b.uploadedAt.localeCompare(a.uploadedAt));
      return json(files);
    }

    if (req.method === "POST") {
      const name = decodeURIComponent(req.headers.get("x-file-name") || "").trim();
      if (!name) return json({ error: "no_name" }, 400);

      const data = await req.arrayBuffer();
      if (data.byteLength === 0) return json({ error: "empty" }, 400);
      if (data.byteLength > MAX_SIZE) return json({ error: "too_big" }, 413);

      const { blobs } = await store.list();
      if (blobs.length >= MAX_FILES) return json({ error: "full" }, 409);

      const key = crypto.randomUUID();
      await store.set(key, data, {
        metadata: { name, size: data.byteLength, uploadedAt: new Date().toISOString() },
      });
      return json({ ok: true, id: key });
    }

    if (req.method === "DELETE") {
      if (!id) return json({ error: "no_id" }, 400);
      await store.delete(id);
      return json({ ok: true });
    }

    return json({ error: "method" }, 405);
  } catch (e) {
    return json({ error: e.message }, 500);
  }
};

export const config = { path: "/api/files" };

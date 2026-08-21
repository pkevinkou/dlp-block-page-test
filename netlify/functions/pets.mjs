import { getStore } from "@netlify/blobs";

const H = { "content-type": "application/json; charset=utf-8" };
const MAX_BODY = 3_000_000;
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: H });

export default async (req) => {
  let store;
  try { store = getStore("pat-pets"); }
  catch (e) { return json({ error: "store init: " + e.message }, 500); }

  try {
    if (req.method === "GET") {
      const { blobs } = await store.list();
      const pets = [];
      for (const b of blobs) {
        const v = await store.get(b.key, { type: "json" });
        if (v) pets.push(v);
      }
      return json(pets);
    }

    if (req.method === "POST") {
      const body = await req.text();
      if (body.length > MAX_BODY) return json({ error: "too_big" }, 413);
      const pet = JSON.parse(body || "{}");
      if (!pet.id || !pet.images || !pet.images.normal) return json({ error: "invalid" }, 400);
      const { blobs } = await store.list();
      if (blobs.length >= 30 && !blobs.some(b => b.key === pet.id)) return json({ error: "full" }, 409);
      await store.set(pet.id, JSON.stringify(pet));
      return json({ ok: true });
    }

    if (req.method === "DELETE") {
      const id = new URL(req.url).searchParams.get("id");
      if (id) await store.delete(id);
      return json({ ok: true });
    }

    return json({ error: "method" }, 405);
  } catch (e) {
    return json({ error: e.message }, 500);
  }
};

export const config = { path: "/api/pets" };

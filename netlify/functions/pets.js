const { getStore } = require("@netlify/blobs");

const H = { "Content-Type": "application/json; charset=utf-8" };
const MAX_BODY = 3_000_000; // 單一寵物上限 ~3MB

exports.handler = async (event) => {
  let store;
  try { store = getStore("pat-pets"); }
  catch (e) { return { statusCode: 500, headers: H, body: JSON.stringify({ error: "store init: " + e.message }) }; }

  try {
    if (event.httpMethod === "GET") {
      const { blobs } = await store.list();
      const pets = [];
      for (const b of blobs) {
        const v = await store.get(b.key, { type: "json" });
        if (v) pets.push(v);
      }
      return { statusCode: 200, headers: H, body: JSON.stringify(pets) };
    }

    if (event.httpMethod === "POST") {
      const body = event.body || "";
      if (body.length > MAX_BODY)
        return { statusCode: 413, headers: H, body: JSON.stringify({ error: "too_big" }) };
      const pet = JSON.parse(body || "{}");
      if (!pet.id || !pet.images || !pet.images.normal)
        return { statusCode: 400, headers: H, body: JSON.stringify({ error: "invalid" }) };
      const { blobs } = await store.list();
      if (blobs.length >= 30 && !blobs.some(b => b.key === pet.id))
        return { statusCode: 409, headers: H, body: JSON.stringify({ error: "full" }) };
      await store.set(pet.id, JSON.stringify(pet));
      return { statusCode: 200, headers: H, body: JSON.stringify({ ok: true }) };
    }

    if (event.httpMethod === "DELETE") {
      const id = (event.queryStringParameters || {}).id;
      if (id) await store.delete(id);
      return { statusCode: 200, headers: H, body: JSON.stringify({ ok: true }) };
    }

    return { statusCode: 405, headers: H, body: JSON.stringify({ error: "method" }) };
  } catch (e) {
    return { statusCode: 500, headers: H, body: JSON.stringify({ error: e.message }) };
  }
};

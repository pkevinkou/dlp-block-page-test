// 純Echo用途：不寫檔、不記log、不存資料庫，處理完立刻捨棄。
exports.handler = async function (event) {
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body || '', 'base64')
    : Buffer.from(event.body || '', 'utf8');

  const preview = raw.toString('utf8', 0, Math.min(raw.length, 300));

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      received_bytes: raw.length,
      content_type: event.headers['content-type'] || null,
      preview: preview
    })
  };
};

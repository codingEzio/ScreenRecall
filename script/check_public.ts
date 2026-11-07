// Inspect indexed files and all reachable history; never print matched values.
const decoder = new TextDecoder();
async function git(...args: string[]): Promise<Uint8Array> {
  const result = await new Deno.Command("git", {
    args: ["--no-replace-objects", ...args],
    cwd: new URL("../", import.meta.url),
    stdout: "piped",
    stderr: "piped",
  }).output();
  if (!result.success) throw new Error("Git inspection failed");
  return result.stdout;
}
// Notes can contain private agent metadata. Snapshot only branch/tag refs;
// refuse every other ref before reading its objects, including Git notes.
const refs = decoder.decode(
  await git("for-each-ref", "--format=%(refname) %(objectname)"),
);
const refRows = refs.trim().split("\n").filter(Boolean).map((line) =>
  line.split(" ")
);
if (
  refRows.some(([name]) =>
    !name.startsWith("refs/heads/") && !name.startsWith("refs/tags/")
  )
) {
  console.error(
    "Non-branch/tag refs exist; review a separate source-only release history.",
  );
  Deno.exit(1);
}
const refObjects = refRows.map(([, oid]) => oid);
if (!refObjects.length) throw new Error("No release history to inspect");
const manifest = JSON.parse(
  decoder.decode(await git("show", ":public-source.json")),
);
const allowed = new Set<string>(manifest.files);
const pins: Record<string, string> = { ...manifest.assets };
for (const font of manifest.fontFiles) {
  pins[`Dependencies/DeparturePixelZh/${font.path}`] = font.sha256;
}
const privatePath =
  /(^|\/)(Local|\.build|\.env(?:\..*)?)(\/|$)|\.(sqlite3?|p12|pem|key)$|-(wal|shm)$/i;
const secret =
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|\bAKIA[A-Z0-9]{16}\b|\bgh[pousr]_[A-Za-z0-9]{30,}\b|\bsk-proj-[A-Za-z0-9_-]{30,}\b|\/Users\/[A-Za-z][^/\s]*\//;
let failures = 0;
async function inspect(path: string, bytes: Uint8Array, indexed: boolean) {
  let reason = privatePath.test(path) ? "runtime/private path" : null;
  if (indexed && !allowed.has(path)) reason = "unreviewed indexed file";
  if (bytes.includes(0) || pins[path]) {
    const hash = Array.from(
      new Uint8Array(
        await crypto.subtle.digest("SHA-256", new Uint8Array(bytes).buffer),
      ),
    ).map((x) => x.toString(16).padStart(2, "0")).join("");
    if (pins[path] !== hash) reason = "unreviewed or changed binary";
  }
  // Product previews must not carry display profiles or other machine metadata.
  if (
    path === "Documentation/product-light.png" ||
    path === "Documentation/product-dark.png"
  ) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    let offset = 8, ended = false;
    if (!signature.every((value, index) => bytes[index] === value)) {
      reason = "invalid PNG";
    }
    while (!reason && offset + 12 <= bytes.length) {
      const length = new DataView(bytes.buffer, bytes.byteOffset + offset, 4)
        .getUint32(0);
      const end = offset + 12 + length;
      if (end > bytes.length) {
        reason = "invalid PNG";
        break;
      }
      const type = decoder.decode(bytes.subarray(offset + 4, offset + 8));
      if (!["IHDR", "IDAT", "IEND"].includes(type)) {
        reason = "PNG metadata requires removal";
        break;
      }
      offset = end;
      if (type === "IEND") {
        ended = true;
        break;
      }
    }
    if (!ended || offset !== bytes.length) reason = reason ?? "invalid PNG";
  }
  if (!bytes.includes(0) && secret.test(decoder.decode(bytes))) {
    reason = "credential or personal path pattern";
  }
  if (reason) {
    console.error(`${path}: ${reason}`);
    failures++;
  }
}
const files = decoder.decode(await git("ls-files", "-z")).split("\0").filter(
  Boolean,
);
for (const file of files) {
  await inspect(file, await git("show", `:${file}`), true);
}
for (const file of allowed) {
  if (!files.includes(file)) {
    console.error(`${file}: missing reviewed file`);
    failures++;
  }
}
const objects = decoder.decode(
  await git("rev-list", "--objects", ...refObjects),
)
  .split("\n").filter(Boolean);
for (const row of objects) {
  const space = row.indexOf(" ");
  if (space < 0) continue;
  const oid = row.slice(0, space), path = row.slice(space + 1);
  if (decoder.decode(await git("cat-file", "-t", oid)).trim() === "blob") {
    await inspect(path, await git("cat-file", "blob", oid), false);
  }
}
const authors = decoder.decode(
  await git("log", ...refObjects, "--format=%an <%ae>%n%cn <%ce>"),
);
for (const author of new Set(authors.trim().split("\n").filter(Boolean))) {
  if (author !== "codingEzio <22790019+codingEzio@users.noreply.github.com>") {
    console.error("Unexpected first-party history identity");
    failures++;
  }
}
if (
  decoder.decode(
    await git("for-each-ref", "--format=%(refname) %(objectname)"),
  ) !== refs
) {
  console.error(
    "Git refs changed during review; repeat in an isolated repository.",
  );
  failures++;
}
console.log(
  `Checked ${files.length} indexed files and ${objects.length} reachable objects; ${failures} findings.`,
);
Deno.exit(failures ? 1 : 0);

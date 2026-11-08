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
// Notes can contain private agent metadata. Snapshot branch/tag refs and
// refuse unknown namespaces before reading their objects, including Git notes.
// Remote-tracking refs are safe only when their commits are already in the
// branch/tag history inspected below; this supports ordinary Git clones.
const refFormat = "--format=%(refname) %(objectname) %(symref)";
const refs = decoder.decode(await git("for-each-ref", refFormat));
const refRows = refs.trim().split("\n").filter(Boolean).map((line) =>
  line.split(" ")
);
const releaseRefs = refRows.filter(([name]) =>
  name.startsWith("refs/heads/") || name.startsWith("refs/tags/")
);
const trackingRefs = refRows.filter(([name]) =>
  name.startsWith("refs/remotes/")
);
if (refRows.length !== releaseRefs.length + trackingRefs.length) {
  console.error(
    "Non-branch/tag refs exist; review a separate source-only release history.",
  );
  Deno.exit(1);
}
const refObjects = releaseRefs.map(([, oid]) => oid);
if (!refObjects.length) throw new Error("No release history to inspect");
const commits = new Set(
  decoder.decode(await git("rev-list", ...refObjects)).trim().split("\n")
    .filter(Boolean),
);
if (trackingRefs.length) {
  if (trackingRefs.some(([, oid]) => !commits.has(oid))) {
    console.error(
      "Remote-tracking refs contain commits outside the reviewed branch/tag history.",
    );
    Deno.exit(1);
  }
}
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
if (secret.test(refs)) {
  console.error("Git ref contains a credential or personal path pattern");
  failures++;
}
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
// rev-list --objects reports only one pathname per object. Walk every commit
// tree as well so a reused blob cannot hide a private historical pathname.
const inspected = new Set<string>();
for (const commit of commits) {
  const entries = decoder.decode(
    await git("ls-tree", "-r", "-z", "--full-tree", commit),
  )
    .split("\0").filter(Boolean);
  for (const entry of entries) {
    const tab = entry.indexOf("\t");
    if (tab < 0) throw new Error("Invalid Git tree entry");
    const [, type, oid] = entry.slice(0, tab).split(" ");
    const path = entry.slice(tab + 1), key = `${oid}\0${path}`;
    if (inspected.has(key)) continue;
    inspected.add(key);
    if (type !== "blob") {
      console.error(`${path}: submodule requires explicit review`);
      failures++;
      continue;
    }
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
for (const commit of commits) {
  const raw = decoder.decode(await git("cat-file", "commit", commit));
  if (secret.test(raw)) {
    console.error(
      "Commit metadata or message contains a credential or personal path pattern",
    );
    failures++;
  }
}
const checkedTags = new Set<string>();
for (const [name, firstOid] of releaseRefs) {
  let oid = firstOid;
  const chain = new Set<string>();
  while (true) {
    const objectType = decoder.decode(await git("cat-file", "-t", oid)).trim();
    if (objectType === "commit") break;
    if (objectType !== "tag" || !name.startsWith("refs/tags/")) {
      console.error("Release refs must resolve to commits");
      failures++;
      break;
    }
    if (chain.has(oid)) {
      console.error("Annotated tag chain is cyclic");
      failures++;
      break;
    }
    if (checkedTags.has(oid)) break;
    chain.add(oid);
    checkedTags.add(oid);
    const tag = decoder.decode(await git("cat-file", "tag", oid));
    const boundary = tag.indexOf("\n\n");
    const header = boundary < 0 ? [] : tag.slice(0, boundary).split("\n");
    const objects = header.filter((line) => line.startsWith("object "));
    const types = header.filter((line) => line.startsWith("type "));
    const taggers = header.filter((line) => line.startsWith("tagger "));
    const target = objects.length === 1
      ? /^object ([0-9a-f]{40}|[0-9a-f]{64})$/.exec(objects[0])?.[1]
      : undefined;
    const declaredType = types.length === 1
      ? /^type (commit|tag)$/.exec(types[0])?.[1]
      : undefined;
    const tagger = taggers.length === 1
      ? /^tagger (.+?) \d+ [+-]\d{4}$/.exec(taggers[0])?.[1]
      : undefined;
    if (!target || !declaredType) {
      console.error("Annotated tag has an invalid target header");
      failures++;
      break;
    }
    if (
      tagger !== "codingEzio <22790019+codingEzio@users.noreply.github.com>" ||
      secret.test(tag)
    ) {
      console.error(
        "Annotated tag contains an unexpected identity or sensitive pattern",
      );
      failures++;
    }
    if (
      decoder.decode(await git("cat-file", "-t", target)).trim() !==
        declaredType
    ) {
      console.error("Annotated tag target type does not match its header");
      failures++;
      break;
    }
    oid = target;
  }
}
if (
  decoder.decode(await git("for-each-ref", refFormat)) !== refs
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

// Revokes the Apple Development certificates that Xcode created on this CI machine.
//
// A CI runner starts with an empty keychain, so automatic signing creates a new development
// certificate on every run until the account's limit is reached. The certificate is only needed
// to archive: TestFlight builds are signed with Apple's cloud-managed distribution certificate.
// Only certificates found in this machine's keychain are revoked.
//
// Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 key file).
import { execFileSync } from 'node:child_process';
import { createPrivateKey, sign, X509Certificate } from 'node:crypto';
import fs from 'node:fs';

const { ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH } = process.env;
const api = 'https://api.appstoreconnect.apple.com/v1';

function token() {
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const unsigned = `${encode({ alg: 'ES256', kid: ASC_KEY_ID, typ: 'JWT' })}.` +
    encode({ iss: ASC_ISSUER_ID, iat: now, exp: now + 600, aud: 'appstoreconnect-v1' });
  const key = createPrivateKey(fs.readFileSync(ASC_KEY_PATH));
  const signature = sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' });
  return `${unsigned}.${signature.toString('base64url')}`;
}

// DER contents (base64) of every certificate in the keychain search list.
function keychainCertificates() {
  let pem = '';
  try {
    pem = execFileSync('security', ['find-certificate', '-a', '-p'], { encoding: 'utf8', maxBuffer: 64 << 20 });
  } catch {
    return new Set();
  }
  const contents = new Set();
  for (const block of pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g) ?? []) {
    try { contents.add(new X509Certificate(block).raw.toString('base64')); } catch { /* not parseable */ }
  }
  return contents;
}

if (!ASC_KEY_ID || !ASC_ISSUER_ID || !ASC_KEY_PATH || !fs.existsSync(ASC_KEY_PATH)) {
  console.log('No App Store Connect key installed; nothing to revoke.');
  process.exit(0);
}

const local = keychainCertificates();
const headers = { Authorization: `Bearer ${token()}` };
const list = await fetch(`${api}/certificates?filter[certificateType]=DEVELOPMENT,IOS_DEVELOPMENT&limit=200`, { headers });
if (!list.ok) {
  console.log(`::warning::Couldn't list certificates (HTTP ${list.status}). Revoke this run's "Created via API" development certificate in the developer portal.`);
  process.exit(0);
}

let revoked = 0;
for (const certificate of (await list.json()).data) {
  const { certificateContent, name, serialNumber } = certificate.attributes;
  if (!local.has(certificateContent)) continue;
  const result = await fetch(`${api}/certificates/${certificate.id}`, { method: 'DELETE', headers });
  if (result.ok) {
    revoked += 1;
    console.log(`Revoked development certificate "${name}" (${serialNumber}).`);
  } else {
    console.log(`::warning::Couldn't revoke development certificate ${serialNumber} (HTTP ${result.status}).`);
  }
}
console.log(`${revoked} development certificate(s) created by this run revoked.`);

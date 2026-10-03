import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, it, expect } from 'vitest';

/**
 * The Pages deployment reads ui/public/_headers, so its policy is only ever as
 * correct as the last person to tighten it. A browser cannot tell us at build
 * time that a font or the bridge stopped loading; these checks fail the build
 * instead, by pinning each allowance to the thing in the source that needs it.
 */
// Not resolved from import.meta.url: this project runs under jsdom, where that
// is an http: URL rather than a file: one. Both plausible working directories
// are tried so the test does not care which one pnpm was invoked from.
const headersPath = [process.cwd(), resolve(process.cwd(), 'ui')]
  .map((dir) => resolve(dir, 'public/_headers'))
  .find(existsSync);

if (headersPath === undefined) {
  throw new Error('ui/public/_headers not found');
}

const raw = readFileSync(headersPath, 'utf8');

/** Headers for one URL pattern, as written in the file (tab or space indented). */
const blockFor = (pattern: string): Map<string, string> => {
  const lines = raw.split('\n').map((l) => l.replace(/\s+$/, ''));
  const start = lines.findIndex((l) => l.trim() === pattern);
  if (start === -1) return new Map();
  const headers = new Map<string, string>();
  for (const line of lines.slice(start + 1)) {
    if (line.trim() === '' || !/^\s/.test(line)) break;
    const at = line.indexOf(':');
    if (at !== -1) headers.set(line.slice(0, at).trim(), line.slice(at + 1).trim());
  }
  return headers;
};

const csp = blockFor('/*').get('Content-Security-Policy') ?? '';

/** Directive -> source expressions, e.g. connect-src -> ["'self'", 'wss:']. */
const directives = new Map(
  csp
    .split(';')
    .map((d) => d.trim())
    .filter((d) => d !== '')
    .map((d) => {
      const [name, ...sources] = d.split(/\s+/);
      return [name, sources] as [string, string[]];
    }),
);

const sourcesFor = (directive: string): string[] => directives.get(directive) ?? [];

describe('_headers Content-Security-Policy', () => {
  it('denies everything by default rather than defaulting to self', () => {
    expect(sourcesFor('default-src')).toEqual(["'none'"]);
  });

  it('enumerates every fetch directive the app relies on', () => {
    // A new resource type with no directive of its own would be blocked by
    // default-src 'none', so the list has to stay explicit.
    for (const directive of ['script-src', 'style-src', 'font-src', 'img-src', 'connect-src']) {
      expect(sourcesFor(directive), directive).not.toEqual([]);
    }
  });

  it('allows only same-origin scripts plus Cloudflare Insights', () => {
    expect(sourcesFor('script-src')).toEqual([
      "'self'",
      "'sha256-Xr8ZXGdI114NdtLEpSRiuIfaCG+8K1JUU1dbe1s/LAg='",
      'https://static.cloudflareinsights.com',
    ]);
  });

  it('allows the Google Fonts stylesheet index.html links to', () => {
    // ui/index.html: <link href="https://fonts.googleapis.com/css2?...">
    expect(sourcesFor('style-src')).toContain('https://fonts.googleapis.com');
  });

  it('allows inline style attributes, which two components use', () => {
    // krivostr-landing.ts and nostr-feed.ts set style="color:var(--mute)".
    expect(sourcesFor('style-src')).toContain("'unsafe-inline'");
  });

  it('allows the font files fonts.gstatic.com serves', () => {
    expect(sourcesFor('font-src')).toContain('https://fonts.gstatic.com');
  });

  it('allows WebSockets to any host, since the bridge origin is not knowable here', () => {
    // 'self' alone is not enough: it does not resolve to WebSocket schemes in
    // every browser (w3c/webappsec-csp#7), and VITE_BRIDGE_URL points
    // somewhere else by design.
    expect(sourcesFor('connect-src')).toContain('wss:');
  });

  it('does not allow cleartext sockets, which an https page would block anyway', () => {
    expect(sourcesFor('connect-src')).not.toContain('ws:');
  });

  it('needs no image host, because remote images are never inserted', () => {
    const img = sourcesFor('img-src');
    expect(img).toContain("'self'");
    expect(img.every((s) => s === "'self'" || s === 'data:')).toBe(true);
  });

  it('forbids plugins, framing and base-tag rewriting', () => {
    expect(sourcesFor('object-src')).toEqual(["'none'"]);
    expect(sourcesFor('frame-ancestors')).toEqual(["'none'"]);
    expect(sourcesFor('base-uri')).toEqual(["'none'"]);
  });

  it('carries the non-CSP security headers alongside it', () => {
    const headers = blockFor('/*');
    expect(headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(headers.get('Referrer-Policy')).toBe('no-referrer');
    expect(headers.get('X-Frame-Options')).toBe('DENY');
  });
});

describe('_headers caching', () => {
  it('caches the fingerprinted bundles forever', () => {
    expect(blockFor('/assets/*').get('Cache-Control')).toBe(
      'public, max-age=31536000, immutable',
    );
  });

  it('revalidates the HTML that names those bundles', () => {
    expect(blockFor('/*.html').get('Cache-Control')).toBe(
      'public, max-age=0, must-revalidate',
    );
  });
});

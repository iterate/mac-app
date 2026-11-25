# The mind's side: a site for this Mac's pages

The Mac serves its pages through the lend: `itx.<name>.http({ method, path, query, headers })`
answers `{ status, headers, body }` (`bridge/pages.mjs`). Nothing in a mind calls it yet. This file
is the userland code that a mind's config repo needs so that a member opens
`https://devices.<domain>/<name>/` in a browser. It is written, not deployed: no mind was changed.

It follows the shapes of iterate.com's config repo as read on 25 November 2026: `worker.ts` routes
each host in `#route` on the first label of the hostname, with the member guard beside the case,
and each app is a module with a `fetch(request, host)` (`apps/record/app.ts` is the model: the
record app on `record.<domain>`).

## 1. The app: `apps/devices/app.ts`

```ts
// app.ts — THIS MAC'S PAGES, on `devices.<domain>/<name>/…`, for members alone (worker.ts guards
// the host before this code runs). Each request goes to the device lent as `itx.<name>`, whose
// `http` answers { status, headers, body } (github.com/iterate/mac-app, bridge/pages.mjs). A body
// that is a ReadableStream (the live view, /live.mjpeg) streams through to the browser; the
// browser's end cancels it, and the cancel reaches the Mac, which stops its capture.
import type { IterateConfigEntrypoint } from "iterate/sdk";

type Host = Pick<IterateConfigEntrypoint, "auth" | "getItx">;
type PageAnswer = {
  status: number;
  headers: Record<string, string>;
  body: string | Uint8Array | ReadableStream<Uint8Array>;
};

/** The rule of `iterate provide` for a name: dotted segments of letters, digits and dashes. */
const NAME = /^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)*$/;

export function devicesApp() {
  return {
    async fetch(request: Request, host: Host): Promise<Response> {
      const page = host.auth.memberPage(request);
      if (page) return page;
      const url = new URL(request.url);
      const [, name, rest] = /^\/([^/]+)(\/.*)?$/.exec(url.pathname) ?? [];
      if (!name || !NAME.test(name)) return new Response("Name a device: /<name>/\n", { status: 404 });
      // the page's links are relative: it needs the slash after the name
      if (rest === undefined) return Response.redirect(`${url.origin}/${name}/`, 308);
      if (request.method !== "GET") return new Response("GET alone\n", { status: 405, headers: { allow: "GET" } });

      // Not `using`: the scope must outlive this call while a body streams. It is disposed when
      // the body ends, or at once for an answer that does not stream.
      const itx = host.getItx();
      let answer: PageAnswer;
      try {
        // `itx.jonas.mac` for the name `jonas.mac`
        const device = name.split(".").reduce((stub: any, part) => stub[part], itx);
        answer = await device.http({
          method: "GET",
          path: rest,
          query: Object.fromEntries(url.searchParams),
          headers: { accept: request.headers.get("accept") ?? "" },
        });
      } catch (error) {
        itx[Symbol.dispose]();
        const words = error instanceof Error ? error.message : String(error);
        return new Response(`${name} does not answer: ${words}\n`, { status: 502 });
      }
      const headers = new Headers(answer.headers);
      headers.set("cache-control", "no-store");
      if (!(answer.body instanceof ReadableStream)) {
        itx[Symbol.dispose]();
        return new Response(answer.body, { status: answer.status, headers });
      }
      // The stream: the browser reads `readable`; when it goes away the runtime cancels
      // `readable`, `pipeTo` then cancels `answer.body`, and capnweb carries that cancel to the
      // Mac (pages.mjs `cancel`: the view ends there at once). The scope ends with the pipe.
      const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
      answer.body
        .pipeTo(writable)
        .catch(() => {})
        .finally(() => itx[Symbol.dispose]());
      return new Response(readable, { status: answer.status, headers });
    },
  };
}
```

## 2. The host in `worker.ts`

Beside the other apps:

```ts
import { devicesApp } from "./apps/devices/app.ts";

// This Mac's pages (apps/devices): each lent Mac's own page and live view, for members.
const devices = devicesApp();
```

And one case in `#route`, beside `record`:

```ts
      case "devices": // each lent device's own pages, for members: devices.<domain>/<name>/ (apps/devices/app.ts)
        return describedApp(request, forMembers("Devices")) || this.auth.require(request) || devices.fetch(request, this);
```

`this.auth.require(request)` is the guard: anyone who is not a signed-in member gets the mind's
sign-in, and the Mac is never asked. `describedApp(…, forMembers(…))` answers the host's manifest,
as the other members' hosts do.

### Or under the apex: `https://<mind>/devices/<name>/…`

The same app, with the prefix taken off, in the apex's case (`case null`) before its other routes:

```ts
        if (new URL(request.url).pathname.startsWith("/devices/")) {
          const inner = new URL(request.url);
          inner.pathname = inner.pathname.slice("/devices".length);
          return this.auth.require(request) || devices.fetch(new Request(inner, request), this);
        }
```

The redirect in the app then goes to `/<name>/` of the origin: change it to
`${url.origin}/devices/${name}/` for this variant. A separate host is simpler: no prefix, and the
apex stays public.

## 3. What the Mac does with it

- The owner's choice for **Pages** (Off, Ask, Shared) decides every request; the live view also
  goes by the display's choice. Off is a `403` with the owner's words, which the site passes on. A
  Mac whose app does not run is a `503`; a Mac that is not lent now makes the call fail: a `502`.
- Under Ask, each request asks the owner. "Approve for 30 Minutes" (Settings › General sets the
  length) lets the page's reads of `state.json` (every 10 s) go with no further question.
- `/live.mjpeg`: at most 4 frames a second, at most 1280 px wide, at most 2 views at once, each
  ended after 10 minutes. The Mac makes a frame only when the reader has taken the last one.

## 4. To check before it is deployed

- The name's lookup through `itx`: one run in the mind's MCP tool,
  `await itx.jonas.mac.http({ path: "/state.json" })`, answers the Mac's state.
- A streamed body through a deployed worker. The bridge's test passes the stream through a capnweb
  session (capnweb 0.13, the installed runtime's) with its cancel, not through a mind.
- That a scope held past the call (no `using`) is allowed by the config repo's lint
  (`iterate/no-raw-itx-get` is a rule of iterate's own repository; the config repo may have it too).

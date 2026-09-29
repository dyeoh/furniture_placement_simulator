// The seam between the simulator and the page it is embedded in. ← host_bridge.gd
//
// Identical wire format to the Godot build: window.postMessage in both
// directions, always as a JSON *string*, so the Shopify section, the smoke
// test and the benchmark drive either build unchanged.
//
// Inbound (host -> sim):  {type:"catalog", finishes, items}
//                         {type:"layout", ...Layout}
//                         {type:"clear"}
//                         {type:"bench", ...}          (bench/scenarios.ts)
// Outbound (sim -> host): {type:"ready", quality, ...}
//                         {type:"layout", ...}          on every change
//                         {type:"add_to_cart", items:[{variant_id, quantity}]}

export function queryParam(name: string): string {
  return new URLSearchParams(location.search).get(name) ?? '';
}

type Handler = (data: Record<string, unknown>) => void;

export class HostBridge {
  private handlers = new Map<string, Handler>();
  private allowedOrigin = '';
  /** Strings posted to ourselves (top level) and not yet seen coming back, with counts. */
  private echoes = new Map<string, number>();

  on(type: string, handler: Handler): void {
    this.handlers.set(type, handler);
  }

  /** [readyExtra] rides along in "ready", e.g. the quality tier chosen. */
  setup(readyExtra: Record<string, unknown> = {}): void {
    // ?host= pins the accepted origin; without it any parent is accepted.
    this.allowedOrigin = queryParam('host');
    window.addEventListener('message', (ev) => {
      // At top level window.parent is this window, so our own outbound
      // "layout" comes straight back in -- restored, re-posted, restored
      // again, forever. Drop the echoes; anything else the page posts to
      // itself (a test, the bench) still gets through.
      if (ev.source === window && typeof ev.data === 'string' && this.takeEcho(ev.data)) return;
      if (this.allowedOrigin && ev.origin !== this.allowedOrigin) return;
      if (typeof ev.data !== 'string') return;
      let data: unknown;
      try { data = JSON.parse(ev.data); } catch { return; }
      if (!data || typeof data !== 'object' || Array.isArray(data)) return;
      const rec = data as Record<string, unknown>;
      this.handlers.get(String(rec.type ?? ''))?.(rec);
    });
    this.post({ type: 'ready', ...readyExtra });
  }

  private takeEcho(text: string): boolean {
    const n = this.echoes.get(text);
    if (!n) return false;
    if (n > 1) this.echoes.set(text, n - 1); else this.echoes.delete(text);
    return true;
  }

  post(msg: object): void {
    // "*": the Pages build does not know which storefront embeds it; the
    // receiving side checks event.origin against the iframe's own URL.
    const text = JSON.stringify(msg);
    if (window.parent === window) this.echoes.set(text, (this.echoes.get(text) ?? 0) + 1);
    window.parent.postMessage(text, '*');
  }
}

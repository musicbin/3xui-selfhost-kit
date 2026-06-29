#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

brand="${MASK_SITE_BRAND:-Hearthline Goods}"
title="${brand} | Home goods and studio essentials"

mkdir -p site
cat > site/index.html <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="Home goods, tableware, textiles, and studio essentials for calm everyday spaces.">
  <title>${title}</title>
  <style>
    :root {
      color-scheme: light;
      --ink: #17201b;
      --muted: #5d6a62;
      --line: #dfe5df;
      --paper: #fafbf8;
      --panel: #ffffff;
      --sage: #607666;
      --clay: #a15d4f;
      --blue: #2f5d7c;
      --gold: #b8893f;
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }

    * { box-sizing: border-box; }
    body { margin: 0; background: var(--paper); color: var(--ink); }
    a { color: inherit; text-decoration: none; }
    .topbar { background: #17201b; color: #f7faf6; font-size: 13px; letter-spacing: .02em; text-align: center; padding: 9px 16px; }
    header { position: sticky; top: 0; z-index: 5; background: rgba(250, 251, 248, .94); border-bottom: 1px solid var(--line); backdrop-filter: blur(12px); }
    .nav { max-width: 1180px; margin: 0 auto; height: 72px; display: flex; align-items: center; justify-content: space-between; padding: 0 24px; gap: 24px; }
    .brand { font-family: Georgia, "Times New Roman", serif; font-size: 25px; letter-spacing: .01em; white-space: nowrap; }
    nav { display: flex; gap: 28px; color: #34443a; font-size: 15px; }
    .nav-actions { display: flex; align-items: center; gap: 14px; color: #34443a; font-size: 14px; }
    .search { border: 1px solid var(--line); background: #fff; border-radius: 999px; padding: 9px 14px; min-width: 190px; color: #738077; }

    main { overflow: hidden; }
    .hero { max-width: 1180px; min-height: 620px; margin: 0 auto; display: grid; grid-template-columns: minmax(0, .95fr) minmax(420px, 1.05fr); gap: 56px; align-items: center; padding: 58px 24px 44px; }
    .eyebrow { color: var(--sage); font-size: 13px; font-weight: 700; letter-spacing: .14em; text-transform: uppercase; margin-bottom: 18px; }
    h1 { font-family: Georgia, "Times New Roman", serif; font-size: clamp(46px, 6vw, 78px); line-height: .98; letter-spacing: 0; margin: 0 0 24px; max-width: 680px; }
    .lead { max-width: 560px; color: var(--muted); font-size: 18px; line-height: 1.75; margin: 0 0 30px; }
    .hero-actions { display: flex; flex-wrap: wrap; gap: 14px; }
    .button { display: inline-flex; align-items: center; justify-content: center; min-height: 46px; padding: 0 20px; border-radius: 999px; border: 1px solid var(--ink); font-weight: 700; }
    .button.primary { background: var(--ink); color: #fff; }
    .button.secondary { background: transparent; color: var(--ink); }

    .editorial { position: relative; min-height: 560px; }
    .scene { position: absolute; inset: 16px 0 0 46px; background: #e7eee6; border: 1px solid #ccd8cf; overflow: hidden; }
    .scene::before { content: ""; position: absolute; inset: 0; background: linear-gradient(90deg, rgba(255,255,255,.42), rgba(255,255,255,0) 34%), repeating-linear-gradient(90deg, rgba(23,32,27,.05) 0 1px, transparent 1px 82px); }
    .shelf { position: absolute; left: 8%; right: 7%; height: 14px; background: #8b6a57; box-shadow: 0 2px 0 rgba(23,32,27,.14); }
    .shelf.one { top: 34%; }
    .shelf.two { top: 63%; }
    .vase { position: absolute; bottom: 37%; left: 17%; width: 90px; height: 130px; background: #f4f0e8; border-radius: 42px 42px 18px 18px; border: 1px solid rgba(23,32,27,.12); }
    .vase::before { content: ""; position: absolute; top: -22px; left: 30px; width: 30px; height: 36px; background: #f4f0e8; border: 1px solid rgba(23,32,27,.12); border-bottom: 0; border-radius: 16px 16px 0 0; }
    .lamp { position: absolute; right: 14%; bottom: 38%; width: 130px; height: 176px; }
    .lamp::before { content: ""; position: absolute; left: 30px; top: 0; width: 74px; height: 54px; background: #d0a64e; border-radius: 44px 44px 18px 18px; }
    .lamp::after { content: ""; position: absolute; left: 64px; top: 54px; width: 8px; height: 122px; background: #4c5b50; }
    .linen { position: absolute; left: 22%; bottom: 8%; width: 250px; height: 132px; background: #b7c5ba; border: 1px solid rgba(23,32,27,.12); }
    .linen::after { content: ""; position: absolute; inset: 18px 0 auto; height: 1px; background: rgba(23,32,27,.18); box-shadow: 0 32px 0 rgba(23,32,27,.12), 0 64px 0 rgba(23,32,27,.1); }
    .art { position: absolute; right: 12%; bottom: 10%; width: 160px; height: 170px; background: #fff; border: 12px solid #f7f2ea; box-shadow: 0 18px 40px rgba(31,42,35,.16); }
    .art::before { content: ""; position: absolute; inset: 28px 22px; border-left: 34px solid var(--clay); border-top: 44px solid transparent; border-bottom: 44px solid transparent; }
    .floating-note { position: absolute; left: 0; bottom: 24px; width: 290px; background: #fff; border: 1px solid var(--line); padding: 18px; box-shadow: 0 22px 60px rgba(31,42,35,.14); }
    .floating-note strong { display: block; margin-bottom: 5px; }
    .floating-note span { color: var(--muted); font-size: 14px; line-height: 1.55; }

    .band { border-top: 1px solid var(--line); border-bottom: 1px solid var(--line); background: #fff; }
    .band-inner { max-width: 1180px; margin: 0 auto; padding: 22px 24px; display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; color: #405047; }
    .band b { color: var(--ink); display: block; margin-bottom: 3px; }

    section { max-width: 1180px; margin: 0 auto; padding: 70px 24px; }
    .section-head { display: flex; align-items: end; justify-content: space-between; gap: 24px; margin-bottom: 28px; }
    h2 { font-family: Georgia, "Times New Roman", serif; font-size: clamp(32px, 4vw, 48px); line-height: 1.05; letter-spacing: 0; margin: 0; }
    .section-head p { color: var(--muted); max-width: 470px; line-height: 1.65; margin: 0; }
    .products { display: grid; grid-template-columns: repeat(4, 1fr); gap: 18px; }
    .product { background: var(--panel); border: 1px solid var(--line); min-width: 0; }
    .product-art { height: 250px; position: relative; overflow: hidden; background: #edf2ed; }
    .product-art::before { content: ""; position: absolute; inset: 24px; border: 1px solid rgba(23,32,27,.1); background: #fff; }
    .ceramic::after { content: ""; position: absolute; left: 50%; top: 42px; width: 92px; height: 150px; transform: translateX(-50%); border-radius: 44px 44px 18px 18px; background: #f4eee3; border: 1px solid #ded4c4; box-shadow: -42px 46px 0 -22px #8f5a4f; }
    .textile::after { content: ""; position: absolute; left: 42px; right: 42px; top: 62px; height: 112px; background: repeating-linear-gradient(0deg, #9fb5aa 0 16px, #c9d5cb 16px 32px); border: 1px solid #93a69b; }
    .lamp-art::after { content: ""; position: absolute; left: 50%; top: 42px; width: 120px; height: 160px; transform: translateX(-50%); background: linear-gradient(#c59445 0 55px, transparent 55px), linear-gradient(90deg, transparent 0 55px, #52645a 55px 64px, transparent 64px); }
    .tray::after { content: ""; position: absolute; left: 44px; right: 44px; bottom: 62px; height: 74px; border-radius: 50%; background: #7d8c84; border: 12px solid #4d665b; box-shadow: 0 26px 0 -18px rgba(23,32,27,.24); }
    .product-body { padding: 16px 16px 18px; }
    .product-title { display: flex; justify-content: space-between; gap: 12px; font-weight: 700; margin-bottom: 7px; }
    .product p { margin: 0; color: var(--muted); font-size: 14px; line-height: 1.55; }

    .story { display: grid; grid-template-columns: .9fr 1.1fr; gap: 36px; align-items: stretch; padding-top: 20px; }
    .story-photo { min-height: 390px; background: #dfe8df; border: 1px solid #c9d4ca; position: relative; overflow: hidden; }
    .story-photo::before { content: ""; position: absolute; inset: 12%; background: #fff; border: 1px solid rgba(23,32,27,.08); box-shadow: 0 28px 70px rgba(31,42,35,.15); }
    .story-photo::after { content: ""; position: absolute; left: 22%; right: 22%; bottom: 20%; height: 42%; background: #5e725f; box-shadow: 80px -72px 0 -24px #bd7b61, -86px -38px 0 -32px #2f5d7c; }
    .story-copy { background: #fff; border: 1px solid var(--line); padding: clamp(28px, 5vw, 52px); display: flex; flex-direction: column; justify-content: center; }
    .story-copy p { color: var(--muted); line-height: 1.75; font-size: 17px; }
    .stats { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; margin-top: 24px; }
    .stat { border-top: 2px solid var(--sage); padding-top: 12px; }
    .stat strong { display: block; font-size: 26px; font-family: Georgia, "Times New Roman", serif; }
    .stat span { color: var(--muted); font-size: 13px; }

    .journal { display: grid; grid-template-columns: repeat(3, 1fr); gap: 18px; }
    .article { border-top: 1px solid var(--line); padding-top: 18px; }
    .article time { color: var(--clay); font-size: 13px; font-weight: 700; }
    .article h3 { font-size: 20px; margin: 10px 0; letter-spacing: 0; }
    .article p { color: var(--muted); line-height: 1.65; margin: 0; }

    .newsletter { background: #17201b; color: #f8faf7; padding: 58px 24px; }
    .newsletter-inner { max-width: 1180px; margin: 0 auto; display: grid; grid-template-columns: 1fr minmax(280px, 420px); gap: 32px; align-items: center; }
    .newsletter h2 { color: #fff; }
    .newsletter p { color: #cbd6ce; line-height: 1.7; }
    .signup { display: flex; background: #fff; padding: 6px; border: 1px solid #33433a; }
    .signup input { flex: 1; border: 0; padding: 0 14px; min-height: 46px; font: inherit; min-width: 0; }
    .signup button { border: 0; background: var(--gold); color: #17201b; font-weight: 800; padding: 0 18px; font: inherit; }

    footer { background: #fff; border-top: 1px solid var(--line); }
    .footer-inner { max-width: 1180px; margin: 0 auto; padding: 30px 24px; display: flex; justify-content: space-between; gap: 18px; color: var(--muted); font-size: 14px; }

    @media (max-width: 900px) {
      nav, .search { display: none; }
      .hero { grid-template-columns: 1fr; min-height: auto; padding-top: 42px; }
      .editorial { min-height: 420px; }
      .scene { left: 22px; }
      .band-inner, .products, .story, .journal, .newsletter-inner { grid-template-columns: 1fr; }
      .section-head { display: block; }
      .section-head p { margin-top: 12px; }
      .products { gap: 14px; }
    }

    @media (max-width: 560px) {
      .nav { height: 64px; padding: 0 16px; }
      .hero, section { padding-left: 16px; padding-right: 16px; }
      .hero-actions, .signup { flex-direction: column; align-items: stretch; }
      .button { width: 100%; }
      .floating-note { width: calc(100% - 32px); left: 16px; }
      .footer-inner { flex-direction: column; }
    }
  </style>
</head>
<body>
  <div class="topbar">Complimentary shipping on orders over \$75 in the continental U.S.</div>
  <header>
    <div class="nav">
      <a class="brand" href="/">${brand}</a>
      <nav aria-label="Primary navigation">
        <a href="#new">New arrivals</a>
        <a href="#studio">Studio</a>
        <a href="#journal">Journal</a>
        <a href="#contact">Contact</a>
      </nav>
      <div class="nav-actions">
        <div class="search">Search tableware, linen, lighting</div>
        <a href="#new">Bag 0</a>
      </div>
    </div>
  </header>

  <main>
    <section class="hero" aria-labelledby="hero-title">
      <div>
        <div class="eyebrow">Spring edit now in stock</div>
        <h1 id="hero-title">Useful pieces for warmer, quieter rooms.</h1>
        <p class="lead">Small-batch ceramics, woven textiles, lighting, and desk objects selected for homes that are lived in every day.</p>
        <div class="hero-actions">
          <a class="button primary" href="#new">Shop the edit</a>
          <a class="button secondary" href="#studio">Book a styling consult</a>
        </div>
      </div>
      <div class="editorial" aria-label="Styled room preview">
        <div class="scene">
          <div class="shelf one"></div>
          <div class="shelf two"></div>
          <div class="vase"></div>
          <div class="lamp"></div>
          <div class="linen"></div>
          <div class="art"></div>
        </div>
        <div class="floating-note">
          <strong>Trade sample sets</strong>
          <span>Material swatches and finish cards ship within two business days for studio and hospitality projects.</span>
        </div>
      </div>
    </section>

    <div class="band">
      <div class="band-inner">
        <div><b>Ships in 1-2 days</b>From our New Jersey packing studio</div>
        <div><b>Small batches</b>Limited runs from independent makers</div>
        <div><b>Easy returns</b>30 days on unused home goods</div>
        <div><b>Trade friendly</b>Quotes for designers and offices</div>
      </div>
    </div>

    <section id="new">
      <div class="section-head">
        <h2>New arrivals</h2>
        <p>Edited essentials with honest materials, quiet color, and details that hold up to everyday use.</p>
      </div>
      <div class="products">
        <article class="product">
          <div class="product-art ceramic"></div>
          <div class="product-body">
            <div class="product-title"><span>Stoneware Stem Vase</span><span>\$68</span></div>
            <p>Hand-finished ceramic with a warm off-white glaze.</p>
          </div>
        </article>
        <article class="product">
          <div class="product-art textile"></div>
          <div class="product-body">
            <div class="product-title"><span>Linen Grid Throw</span><span>\$124</span></div>
            <p>Washed linen blend for sofas, reading chairs, and guest rooms.</p>
          </div>
        </article>
        <article class="product">
          <div class="product-art lamp-art"></div>
          <div class="product-body">
            <div class="product-title"><span>Ochre Table Lamp</span><span>\$210</span></div>
            <p>Compact task light with a powder-coated steel shade.</p>
          </div>
        </article>
        <article class="product">
          <div class="product-art tray"></div>
          <div class="product-body">
            <div class="product-title"><span>Forest Catchall Tray</span><span>\$42</span></div>
            <p>Glazed valet tray for entry tables and office shelves.</p>
          </div>
        </article>
      </div>
    </section>

    <section id="studio" class="story">
      <div class="story-photo" aria-hidden="true"></div>
      <div class="story-copy">
        <div class="eyebrow">Studio services</div>
        <h2>Room-ready sourcing for homes, offices, and small hospitality spaces.</h2>
        <p>Our studio team builds practical mood boards, finish palettes, and product lists for people who want a finished space without a months-long design process.</p>
        <div class="stats">
          <div class="stat"><strong>48h</strong><span>quote turnaround</span></div>
          <div class="stat"><strong>220+</strong><span>maker partners</span></div>
          <div class="stat"><strong>30</strong><span>day returns</span></div>
        </div>
      </div>
    </section>

    <section id="journal">
      <div class="section-head">
        <h2>Notes from the studio</h2>
        <p>Short guides on setting a table, choosing finishes, and keeping rooms easy to maintain.</p>
      </div>
      <div class="journal">
        <article class="article">
          <time>June 12</time>
          <h3>How to mix ceramic finishes without making a shelf feel busy</h3>
          <p>Start with one matte base, repeat a single accent tone, and let scale do the rest.</p>
        </article>
        <article class="article">
          <time>May 29</time>
          <h3>Three durable fabrics we use for rental homes and guest rooms</h3>
          <p>Washed linen blends, tight basket weaves, and recycled wool keep their shape.</p>
        </article>
        <article class="article">
          <time>May 03</time>
          <h3>A practical checklist for styling an entry table</h3>
          <p>One tray, one lamp, one catchall, and enough open space for real life.</p>
        </article>
      </div>
    </section>
  </main>

  <section id="contact" class="newsletter">
    <div class="newsletter-inner">
      <div>
        <h2>Get restock notes and studio updates.</h2>
        <p>One concise email each month with new pieces, trade availability, and practical home notes.</p>
      </div>
      <form class="signup" action="/" method="get">
        <input aria-label="Email address" type="email" placeholder="Email address">
        <button type="submit">Join list</button>
      </form>
    </div>
  </section>

  <footer>
    <div class="footer-inner">
      <div>© 2026 ${brand}. All rights reserved.</div>
      <div>Trade inquiries · Shipping · Returns · Privacy</div>
    </div>
  </footer>
</body>
</html>
EOF

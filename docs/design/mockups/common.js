// Shared mockup script: host status bar, a few line icons, vector device bodies. The device bodies are all simplified shapes we draw ourselves, with no logos or trademark wording.
// SPDX-License-Identifier: GPL-2.0-or-later

let uid = 0;

/** The host phone's status bar, Dynamic Island and home indicator. color is the color of the text and icons */
function hostChrome(color, indicator) {
  const c = color;
  const html = `
  <div class="sb" style="color:${c}">
    <span class="time">12:19</span>
    <span class="right">
      <svg width="18" height="12" viewBox="0 0 18 12"><g fill="${c}">
        <rect x="0" y="8" width="3" height="4" rx="1"/><rect x="5" y="5.5" width="3" height="6.5" rx="1"/>
        <rect x="10" y="3" width="3" height="9" rx="1"/><rect x="15" y="0" width="3" height="12" rx="1"/></g></svg>
      <svg width="16" height="12" viewBox="0 0 16 12"><g fill="none" stroke="${c}" stroke-width="2" stroke-linecap="round">
        <path d="M1.5 4.2a9.5 9.5 0 0 1 13 0"/><path d="M4.2 7a5.6 5.6 0 0 1 7.6 0"/></g>
        <circle cx="8" cy="10.2" r="1.5" fill="${c}"/></svg>
      <svg width="27" height="13" viewBox="0 0 27 13"><rect x=".5" y=".5" width="23" height="12" rx="3.5" fill="none" stroke="${c}" opacity=".4"/>
        <rect x="2" y="2" width="17" height="9" rx="2" fill="${c}"/><rect x="25" y="4.5" width="1.6" height="4" rx=".8" fill="${c}" opacity=".45"/></svg>
    </span>
  </div>
  <div class="island"></div>
  <div class="homeind" style="background:${indicator || c}"></div>`;
  document.body.insertAdjacentHTML('beforeend', html);
}

/** Line icon; size is the side length, color is the stroke color */
function icon(name, size, color, weight) {
  const s = size || 22, c = color || 'currentColor', w = weight || 2;
  const p = {
    tray: `<path d="M12 3.5v10M7.5 9.5 12 14l4.5-4.5"/><path d="M4 13.5v4.5a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-4.5"/>`,
    bolt: `<path d="M13.5 2.5 5 13.5h6l-1 8 8.5-11h-6z" fill="${c}" stroke-linejoin="round"/>`,
    boltOutline: `<path d="M13.5 2.5 5 13.5h6l-1 8 8.5-11h-6z" stroke-linejoin="round"/>`,
    chevron: `<path d="M9 5l7 7-7 7"/>`,
    back: `<path d="M15 4.5 7.5 12l7.5 7.5"/>`,
    power: `<path d="M12 3v8"/><path d="M6.6 6.4a8 8 0 1 0 10.8 0"/>`,
    home: `<circle cx="12" cy="12" r="8.5"/><rect x="8.6" y="8.6" width="6.8" height="6.8" rx="1.8" opacity="0"/>`,
    ring: `<circle cx="12" cy="12" r="8.5"/>`,
    more: `<circle cx="5.5" cy="12" r="1.4" fill="${c}"/><circle cx="12" cy="12" r="1.4" fill="${c}"/><circle cx="18.5" cy="12" r="1.4" fill="${c}"/>`,
    play: `<path d="M8 5.5v13l10.5-6.5z" fill="${c}" stroke-linejoin="round"/>`,
    info: `<circle cx="12" cy="12" r="9"/><path d="M12 11v6"/><circle cx="12" cy="7.6" r=".6" fill="${c}"/>`,
    pause: `<path d="M9 6v12M15 6v12"/>`,
    clock: `<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>`,
    help: `<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.6 2.6 0 0 1 5 .9c0 1.7-2.5 2.2-2.5 3.8"/><circle cx="12" cy="17.2" r=".6" fill="${c}"/>`,
    list: `<path d="M8.5 6.5h11M8.5 12h11M8.5 17.5h11"/><circle cx="4.5" cy="6.5" r=".9" fill="${c}"/><circle cx="4.5" cy="12" r=".9" fill="${c}"/><circle cx="4.5" cy="17.5" r=".9" fill="${c}"/>`,
  }[name];
  return `<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="${c}" stroke-width="${w}"
           stroke-linecap="round" stroke-linejoin="round" style="display:block">${p}</svg>`;
}

/**
 * Front of the device body. kind: ipod2 (chrome edge, no earpiece), 3gs (rounded, earpiece), 4 (flat sides, steel band, earpiece and front camera).
 * width is the body width (pt); screen is the image shown on the screen (optional; when empty, dark glass is drawn).
 * Shapes are simplified from each model's proportions; screens are all 2:3.
 */
function device(kind, width, screen) {
  const id = 'd' + (++uid);
  const spec = {
    ipod2: { h: 178, top: 32, rx: 15, rim: '#d9dce1', rimW: 3.2, ear: false, cam: false },
    '3gs': { h: 190, top: 38, rx: 17, rim: "#62656c", rimW: 1.4, ear: true, cam: false },
    '4':   { h: 196, top: 41, rx: 10, rim: '#a7abb2', rimW: 3.6, ear: true, cam: true },
  }[kind];
  const H = spec.h, sx = 12, sw = 76, sh = 114, sy = spec.top;
  const hy = sy + sh + (H - sy - sh) / 2;
  const img = screen
    ? `<image href="${screen}" x="${sx}" y="${sy}" width="${sw}" height="${sh}" preserveAspectRatio="none"/>`
    : `<rect x="${sx}" y="${sy}" width="${sw}" height="${sh}" fill="url(#${id}s)"/>`;
  return `<svg width="${width}" height="${width * H / 100}" viewBox="0 0 100 ${H}" style="display:block;overflow:visible">
    <defs>
      <linearGradient id="${id}b" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#3b3d42"/><stop offset=".45" stop-color="#121316"/><stop offset="1" stop-color="#050506"/></linearGradient>
      <linearGradient id="${id}r" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stop-color="#8d9096"/><stop offset=".5" stop-color="${spec.rim}"/><stop offset="1" stop-color="#7a7d83"/></linearGradient>
      <linearGradient id="${id}s" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#34405e"/><stop offset=".55" stop-color="#1a2133"/><stop offset="1" stop-color="#10141f"/></linearGradient>
      <linearGradient id="${id}g" x1="0" y1="0" x2="1" y2="1">
        <stop offset="0" stop-color="#fff" stop-opacity=".18"/><stop offset=".42" stop-color="#fff" stop-opacity=".04"/>
        <stop offset=".43" stop-color="#fff" stop-opacity="0"/></linearGradient>
      <radialGradient id="${id}h" cx=".5" cy=".35" r=".7">
        <stop offset="0" stop-color="#050506"/><stop offset="1" stop-color="#26282c"/></radialGradient>
    </defs>
    <rect x="0" y="0" width="100" height="${H}" rx="${spec.rx}" fill="url(#${id}r)"/>
    <rect x="${spec.rimW}" y="${spec.rimW}" width="${100 - 2 * spec.rimW}" height="${H - 2 * spec.rimW}"
          rx="${spec.rx - spec.rimW * 0.7}" fill="url(#${id}b)"/>
    ${spec.ear ? `<rect x="41" y="${sy / 2 - 1.8}" width="18" height="3.4" rx="1.7" fill="#2a2c30" stroke="#000" stroke-width=".4"/>` : ''}
    ${spec.cam ? `<circle cx="33" cy="${sy / 2}" r="2.2" fill="#15161a" stroke="#34363b" stroke-width=".6"/>` : ''}
    ${img}
    <rect x="${sx}" y="${sy}" width="${sw}" height="${sh}" fill="none" stroke="#000" stroke-width=".6"/>
    <circle cx="50" cy="${hy}" r="9.5" fill="url(#${id}h)" stroke="#3c3e43" stroke-width=".8"/>
    <rect x="${spec.rimW}" y="${spec.rimW}" width="${100 - 2 * spec.rimW}" height="${H - 2 * spec.rimW}"
          rx="${spec.rx - spec.rimW * 0.7}" fill="url(#${id}g)"/>
  </svg>`;
}

/** Replace the data-device="kind width [screen]" placeholders in the page with device bodies */
function fillDevices() {
  document.querySelectorAll('[data-device]').forEach(el => {
    const [kind, w, screen] = el.dataset.device.split(' ');
    el.innerHTML = device(kind, Number(w), screen);
  });
  document.querySelectorAll('[data-icon]').forEach(el => {
    const [name, size, color, weight] = el.dataset.icon.split(' ');
    el.innerHTML = icon(name, Number(size), color, weight && Number(weight));
  });
}

/** Line-drawn device body (outline only), for the typography-style proposal. kind is the same as device(), color is the line color */
function deviceLine(kind, width, color) {
  const spec = { ipod2: { h: 178, top: 32, rx: 15, ear: false, cam: false },
                 '3gs': { h: 190, top: 38, rx: 17, ear: true, cam: false },
                 '4':   { h: 196, top: 41, rx: 10, ear: true, cam: true } }[kind];
  const H = spec.h, sy = spec.top, hy = sy + 114 + (H - sy - 114) / 2, c = color || '#111';
  return `<svg width="${width}" height="${width * H / 100}" viewBox="-2 -2 104 ${H + 4}" style="display:block" fill="none" stroke="${c}" stroke-width="4">
    <rect x="0" y="0" width="100" height="${H}" rx="${spec.rx}"/>
    <rect x="12" y="${sy}" width="76" height="114" stroke-width="3"/>
    ${spec.ear ? `<path d="M42 ${sy / 2}h16" stroke-linecap="round"/>` : ''}
    ${spec.cam ? `<circle cx="32" cy="${sy / 2}" r="2" stroke-width="3"/>` : ''}
    <circle cx="50" cy="${hy}" r="9" stroke-width="3"/>
  </svg>`;
}
document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('[data-line]').forEach(el => {
    const [kind, w, color] = el.dataset.line.split(' ');
    el.innerHTML = deviceLine(kind, Number(w), color);
  });
});

/* validate.pics — shared client script.
   Reads localized strings/data from window.SITE (inlined per page by the
   generator). Two jobs:
   1. Accept-Language SUGGESTION banner — suggestion only, never a redirect.
   2. Home-page toys: format scroller, format tooltip, "ALL OF THEM!" gag.
*/
(function () {
	'use strict';
	if (!window.SITE) return;

	/* ── 1. Language suggestion banner ───────────────────────── */
	// Map a BCP-47 browser tag to one of our locale codes, with the same
	// Chinese region→script folding the app's locale parser uses.
	function matchLocale(tag) {
		tag = String(tag || '').toLowerCase().replace(/_/g, '-');
		if (!tag) return null;
		if (tag === 'zh' || /^zh-(cn|sg|my)\b/.test(tag)) return 'zh_hans';
		if (/^zh-(tw|hk|mo)\b/.test(tag)) return 'zh_hant';
		if (/^zh-hant/.test(tag)) return 'zh_hant';
		if (/^zh-hans/.test(tag)) return 'zh_hans';
		var norm = tag.replace(/-/g, '_');
		if (SITE.locales[norm]) return norm;
		var base = tag.split('-')[0];
		if (base === 'pt' && /^pt-br/.test(tag)) return 'pt_br';
		if (SITE.locales[base]) return base;
		return null;
	}

	function pagePath(slug) {
		var p = slug ? '/' + slug + '/' : '/';
		return SITE.page === 'coverage' ? p + 'coverage/' : p;
	}

	try {
		var dismissed = localStorage.getItem('mv-lang-banner-dismissed');
		var tags = navigator.languages || [navigator.language];
		var want = null;
		for (var i = 0; i < tags.length && !want; i++) want = matchLocale(tags[i]);
		if (!dismissed && want && want !== SITE.lang) {
			var loc = SITE.locales[want];
			var banner = document.getElementById('lang-banner');
			var msg = document.createElement('span');
			msg.textContent = SITE.banner.available.replace('%s', loc.native);
			var go = document.createElement('a');
			go.className = 'banner-switch';
			go.href = pagePath(loc.slug);
			go.textContent = SITE.banner.switchLabel;
			var no = document.createElement('button');
			no.type = 'button';
			no.textContent = SITE.banner.dismiss;
			no.addEventListener('click', function () {
				try { localStorage.setItem('mv-lang-banner-dismissed', '1'); } catch (e) {}
				banner.hidden = true;
				document.body.classList.remove('has-banner');
			});
			banner.appendChild(msg);
			banner.appendChild(go);
			banner.appendChild(no);
			banner.hidden = false;
			document.body.classList.add('has-banner');
		}
	} catch (e) { /* banner is best-effort */ }

	/* ── 2. Home-page toys ───────────────────────────────────── */
	var track = document.getElementById('scroller-track');
	if (!track || !SITE.formats) return; // not the home page

	var currentEl = document.getElementById('ext-current');
	var nextEl = document.getElementById('ext-next');
	var catEl = document.getElementById('category-badge');
	var formats = SITE.formats; // [[ext, catKey], ...]
	var idx = 0;

	currentEl.textContent = '.' + formats[0][0];
	catEl.textContent = SITE.cats[formats[0][1]];

	function cycle() {
		var nextIdx = (idx + 1) % formats.length;
		nextEl.textContent = '.' + formats[nextIdx][0];
		catEl.textContent = SITE.cats[formats[nextIdx][1]];
		track.style.transition = 'transform 0.25s cubic-bezier(0.4, 0, 0.2, 1)';
		track.style.transform = 'translateY(-2.2em)';
		setTimeout(function () {
			track.style.transition = 'none';
			track.style.transform = 'translateY(0)';
			currentEl.textContent = '.' + formats[nextIdx][0];
			nextEl.textContent = '';
			idx = nextIdx;
		}, 250);
	}
	setInterval(cycle, 500);

	/* "How many files?" → "ALL OF THEM!" impact (port of the original). */
	var taglineArea = document.getElementById('tagline-area');
	var originalTagline = taglineArea.innerHTML;
	taglineArea.addEventListener('click', function (e) {
		if (!e.target.classList.contains('how-many-btn')) return;
		var area = taglineArea;

		try {
			var ctx = new (window.AudioContext || window.webkitAudioContext)();
			var dur = 0.6;
			var buf = ctx.createBuffer(1, ctx.sampleRate * dur, ctx.sampleRate);
			var d = buf.getChannelData(0);
			for (var i = 0; i < d.length; i++) {
				var t = i / ctx.sampleRate;
				d[i] = Math.sin(t * 40 * Math.PI * 2) * Math.exp(-t * 8) * 0.7
					+ Math.sin(t * 80 * Math.PI * 2) * Math.exp(-t * 12) * 0.3
					+ (Math.random() * 2 - 1) * Math.exp(-t * 30) * 0.3;
			}
			var src = ctx.createBufferSource();
			src.buffer = buf;
			src.connect(ctx.destination);
			src.start(ctx.currentTime + 0.38);
		} catch (e2) {}

		area.textContent = '';
		var box = document.createElement('div');
		box.className = 'impact-container';
		box.id = 'impact-box';
		var txt = document.createElement('div');
		txt.className = 'impact-text';
		txt.textContent = SITE.impact.allOfThem;
		var overlay = document.createElement('div');
		overlay.className = 'crack-overlay';
		box.appendChild(txt);
		box.appendChild(overlay);
		var sub = document.createElement('div');
		sub.className = 'subtext-fade';
		sub.textContent = SITE.impact.goal;
		area.appendChild(box);
		area.appendChild(sub);

		// Glass-fracture cracks: radial spokes + concentric arcs.
		var w = box.offsetWidth, h = box.offsetHeight;
		var cx = w / 2, cy = h / 2;
		var svgNS = 'http://www.w3.org/2000/svg';
		var svg = document.createElementNS(svgNS, 'svg');
		svg.setAttribute('class', 'crack-svg');
		var pad = 560;
		svg.setAttribute('viewBox', '0 0 ' + (w + pad * 2) + ' ' + (h + pad * 2));
		svg.style.left = -pad + 'px';
		svg.style.top = -pad + 'px';
		svg.style.width = (w + pad * 2) + 'px';
		svg.style.height = (h + pad * 2) + 'px';
		overlay.appendChild(svg);
		var scx = cx + pad, scy = cy + pad;

		function addPath(d, totalLen, delay, strokeW, opacity) {
			var path = document.createElementNS(svgNS, 'path');
			path.setAttribute('class', 'crack-path');
			path.setAttribute('d', d);
			path.style.setProperty('--crack-total-len', Math.ceil(totalLen));
			path.style.setProperty('--crack-delay', delay + 's');
			path.style.stroke = 'rgba(60,50,40,' + opacity + ')';
			path.style.strokeWidth = strokeW;
			svg.appendChild(path);
		}

		var numRadials = 10 + Math.floor(Math.random() * 5);
		var radii = [60, 135, 235, 360, 525];
		var radialPoints = [];
		for (var r0 = 0; r0 < radii.length; r0++) radialPoints.push([]);

		for (var ri = 0; ri < numRadials; ri++) {
			var baseAngle = (ri / numRadials) * Math.PI * 2 + (Math.random() - 0.5) * 0.3;
			var px = scx, py = scy;
			var dStr = 'M' + px.toFixed(1) + ',' + py.toFixed(1);
			var pathLen = 0;
			var angle = baseAngle;
			for (var rr = 0; rr < radii.length; rr++) {
				var targetR = radii[rr] + (Math.random() - 0.5) * 20;
				angle = baseAngle + (Math.random() - 0.5) * 0.25;
				var nx = scx + Math.cos(angle) * targetR;
				var ny = scy + Math.sin(angle) * targetR;
				dStr += ' L' + nx.toFixed(1) + ',' + ny.toFixed(1);
				pathLen += Math.sqrt((nx - px) * (nx - px) + (ny - py) * (ny - py));
				radialPoints[rr].push({ x: nx, y: ny });
				px = nx; py = ny;
			}
			addPath(dStr, pathLen, 0.40 + ri * 0.008, 1.2 + Math.random() * 0.8, 0.25 + Math.random() * 0.1);
		}

		for (var rj = 1; rj < radii.length; rj++) {
			var pts = radialPoints[rj];
			if (pts.length < 2) continue;
			pts.sort(function (a, b) {
				return Math.atan2(a.y - scy, a.x - scx) - Math.atan2(b.y - scy, b.x - scx);
			});
			for (var pi = 0; pi < pts.length; pi++) {
				if (Math.random() > 0.5) continue;
				var a = pts[pi];
				var b = pts[(pi + 1) % pts.length];
				var mx = (a.x + b.x) / 2 + (Math.random() - 0.5) * 14;
				var my = (a.y + b.y) / 2 + (Math.random() - 0.5) * 14;
				var dd = 'M' + a.x.toFixed(1) + ',' + a.y.toFixed(1) +
					' L' + mx.toFixed(1) + ',' + my.toFixed(1) +
					' L' + b.x.toFixed(1) + ',' + b.y.toFixed(1);
				var segLen = Math.sqrt(Math.pow(mx - a.x, 2) + Math.pow(my - a.y, 2)) +
					Math.sqrt(Math.pow(b.x - mx, 2) + Math.pow(b.y - my, 2));
				addPath(dd, segLen, 0.45 + rj * 0.04, 1.0, 0.18 + Math.random() * 0.08);
			}
		}

		setTimeout(function () { area.innerHTML = originalTagline; }, 6000);
	});
})();

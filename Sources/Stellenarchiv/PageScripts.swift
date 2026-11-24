import Foundation

/// JavaScript, das vor dem Export Cookie-Banner wegklickt und gekürzte Inhalte aufklappt.
enum PageScripts {

    /// Läuft als User-Script in ALLEN Frames (auch in fremden Consent-iframes wie Sourcepoint).
    /// Klickt bevorzugt „Ablehnen / Nur notwendige“, sonst „Akzeptieren“.
    static let autoConsent = #"""
    (() => {
      if (window.__saConsent) return; window.__saConsent = true;
      const inFrame = window !== window.top;
      const CONSENT_CTX = /cookie|consent|cmp|gdpr|dsgvo|privacy|datenschutz|onetrust|usercentrics|didomi|cookiebot|borlabs|klaro|sp_message|truste|qc-cmp|fc-consent|cc-window|cookiehub|iubenda|termly|osano/i;
      const frameIsConsent = inFrame && /consent|privacy|cmp|cookie|gdpr|sourcepoint|privacy-mgmt|usercentrics|onetrust|didomi|truste|cookiebot|quantcast|sp_message/i.test(location.href + ' ' + document.title);

      const REJECT_SEL = [
        '#onetrust-reject-all-handler', '.ot-pc-refuse-all-handler',
        '#CybotCookiebotDialogBodyButtonDecline', '#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll',
        '[data-testid="uc-deny-all-button"]', 'button[data-action-type="deny"]',
        '#didomi-notice-disagree-button', '.didomi-continue-without-agreeing',
        '.sp_choice_type_REJECT_ALL', '.sp_choice_type_13',
        '.cmpboxbtnno', '.fc-cta-do-not-consent', '.cc-deny',
        '#truste-consent-required', '[data-cookie-refuse]', '._brlbs-refuse-btn', '._brlbs-refuse',
        '.cm-btn-decline', '.qc-cmp2-summary-buttons button[mode="secondary"]',
        '#cookiescript_reject', '.iubenda-cs-reject-btn', '[data-cky-tag="reject-button"]',
        '.cmplz-deny', '#cn-refuse-cookie', '.moove-gdpr-infobar-reject-btn'
      ];
      const ACCEPT_SEL = [
        '#onetrust-accept-btn-handler', '#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll',
        '#CybotCookiebotDialogBodyButtonAccept', '[data-testid="uc-accept-all-button"]',
        '#didomi-notice-agree-button', '.sp_choice_type_11', '.cmpboxbtnyes', '.fc-cta-consent',
        '.cc-allow', '.cc-dismiss', '#truste-consent-button', '._brlbs-btn-accept-all',
        '.cm-btn-accept-all', '.qc-cmp2-summary-buttons button[mode="primary"]',
        '#cookiescript_accept', '.iubenda-cs-accept-btn', '[data-cky-tag="accept-button"]',
        '.cmplz-accept', '#cn-accept-cookie', '.moove-gdpr-infobar-allow-all'
      ];
      const REJECT_TXT = /^(alle\s+)?((optionalen?|zusätzlichen?|nicht\s+notwendigen?)\s+)?(cookies\s+)?(ablehnen|verweigern|nicht\s+zustimmen|nicht\s+einverstanden|nicht\s+akzeptieren|nicht\s+zulassen)\b|nur\s+(technisch\s+)?(notwendige|erforderliche|essenzielle|essentielle|funktionale)|notwendige\s+cookies\s+(akzeptieren|zulassen)|^weiter\s+ohne|^ohne\s+(einwilligung|zustimmung)|reject(\s+all)?|^decline|only\s+(necessary|essential|required)|(necessary|essential)\s+(cookies\s+)?only|continue\s+without|tout\s+refuser|^refuser/i;
      const ACCEPT_TXT = /^(alle\s+)?(cookies\s+)?(akzeptieren|annehmen|zustimmen|zulassen|erlauben)|alle\s+(cookies\s+)?(akzeptieren|annehmen|zulassen|erlauben)|^(ich\s+)?(bin\s+)?einverstanden|^(ich\s+)?stimme\s+zu|^verstanden|^accept(\s+all)?(\s+cookies)?$|^(i\s+)?agree|^allow(\s+all)?|^got\s+it|^tout\s+accepter|^ok(ay)?$/i;

      const all = (root, out = []) => {
        for (const el of root.querySelectorAll('*')) {
          out.push(el);
          if (el.shadowRoot) all(el.shadowRoot, out);
        }
        return out;
      };
      // Wann wurde ein Element zuletzt geklickt? Erneuter Klick erst nach 1,5 s (Banner evtl. noch nicht bereit)
      const lastClick = new WeakMap();
      const clickable = el => { const t = lastClick.get(el); return !t || Date.now() - t > 1500; };
      const visible = el => {
        const r = el.getBoundingClientRect();
        if (r.width < 2 || r.height < 2) return false;
        const cs = getComputedStyle(el);
        return cs.visibility !== 'hidden' && cs.display !== 'none' && cs.opacity !== '0';
      };
      const inConsentCtx = el => {
        if (frameIsConsent) return true;
        for (let n = el; n; n = n.parentNode || n.host) {
          if (n.nodeType !== 1) continue;
          const sig = (n.id || '') + ' ' + (typeof n.className === 'string' ? n.className : '') + ' ' +
                      (n.getAttribute('aria-label') || '') + ' ' + (n.getAttribute('aria-describedby') || '') + ' ' + n.tagName;
          if (CONSENT_CTX.test(sig)) return true;
          if ((n.getAttribute('role') === 'dialog' || n.tagName === 'DIALOG') && /cookie|datenschutz|privacy|consent|einwillig/i.test(n.textContent || '')) return true;
        }
        return false;
      };
      const label = el => (el.innerText || el.textContent || el.value || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();

      const report = m => { try { window.webkit.messageHandlers.sa.postMessage((inFrame ? '[iframe ' + location.host + '] ' : '') + m); } catch (e) {} };
      let clicks = 0, lastReject = 0;
      const tryClick = () => {
        // 1. bekannte Selektoren (auch in Shadow-DOMs)
        const elems = all(document);
        for (const list of [REJECT_SEL, ACCEPT_SEL]) {
          for (const sel of list) {
            const el = elems.find(e => e.matches && e.matches(sel) && visible(e));
            if (el && clickable(el)) { report('selector ' + sel); lastClick.set(el, Date.now()); el.click(); return true; }
            if (el) return true;
          }
        }
        // 2. Buttons nach Beschriftung, nur im Consent-Kontext
        const btns = elems.filter(e => e.matches && e.matches('button, a, [role="button"], input[type="button"], input[type="submit"]') && visible(e));
        // Nach einem Ablehnen-Klick kurz warten, bevor ggf. doch „Akzeptieren“ nötig ist
        const phases = Date.now() - lastReject < 3000 ? [REJECT_TXT] : [REJECT_TXT, ACCEPT_TXT];
        for (const re of phases) {
          const el = btns.find(b => isConsentButton(b, re));
          if (el && clickable(el)) { report('text "' + label(el) + '"'); lastClick.set(el, Date.now()); if (re === REJECT_TXT) lastReject = Date.now(); el.click(); return true; }
          if (el) return true;
        }
        return false;
      };
      const isConsentButton = (b, re) => { const t = label(b); return t.length > 0 && t.length < 60 && re.test(t) && inConsentCtx(b); };
      const consentButtons = () => all(document).filter(e => e.matches && e.matches('button, a, [role="button"], input[type="button"], input[type="submit"]')
        && visible(e) && (isConsentButton(e, REJECT_TXT) || isConsentButton(e, ACCEPT_TXT)));

      // Status für den Export: steht noch ein Banner?
      const markState = () => {
        if (inFrame) return;
        try { document.documentElement.setAttribute('data-sa-consent', consentButtons().length ? 'open' : 'closed'); } catch (e) {}
      };

      // Letzte Absicherung vor dem PDF: verbliebene Banner samt Overlay ausblenden
      window.__saHideConsent = () => {
        let hidden = 0;
        for (const b of consentButtons()) {
          let box = null;
          for (let n = b; n && n !== document.body && n !== document.documentElement; n = n.parentNode || n.host) {
            if (n.nodeType !== 1) continue;
            const cs = getComputedStyle(n);
            if (n.tagName === 'DIALOG' || n.getAttribute('role') === 'dialog' || n.getAttribute('aria-modal') === 'true'
                || /modal|overlay|banner|consent|cookie/i.test((n.id || '') + ' ' + (typeof n.className === 'string' ? n.className : '') + ' ' + n.tagName)
                || cs.position === 'fixed') box = n;
            if (n.parentNode && n.parentNode.host) { box = n.parentNode.host; }   // ganzen Web-Component-Host nehmen
          }
          if (box && box !== document.body && box !== document.documentElement) {
            box.style.setProperty('display', 'none', 'important'); hidden++;
          }
        }
        // Abdunkelnde Overlays (Backdrops)
        for (const el of document.querySelectorAll('.modal-backdrop, [class*="backdrop" i], [class*="overlay" i]')) {
          const cs = getComputedStyle(el);
          if (cs.position === 'fixed') el.style.setProperty('display', 'none', 'important');
        }
        document.body && document.body.classList.remove('modal-open');
        markState();
        return hidden;
      };

      const started = Date.now();
      const timer = setInterval(() => {
        try { if (tryClick()) clicks++; } catch (e) {}
        markState();
        if (clicks >= 8 || Date.now() - started > 25000) clearInterval(timer);
      }, 400);
    })();
    """#

    /// Klappt „Mehr anzeigen“-Bereiche auf. Gibt die Zahl der Klicks zurück.
    /// (Body für callAsyncJavaScript.)
    static let expand = #"""
    const MORE = /^\s*[+▾▼›»]?\s*(mehr\s+anzeigen|mehr\s+lesen|mehr\s+dazu|weiterlesen|weiter\s+lesen|mehr\s+details|details\s+anzeigen|alles\s+lesen|ganze[ns]?\s+(text|beschreibung|anzeige)\s+(anzeigen|lesen)|vollständige\s+(stellen)?(anzeige|beschreibung|text)(\s+anzeigen)?|stellenbeschreibung\s+anzeigen|beschreibung\s+anzeigen|ausklappen|aufklappen|show\s+more|read\s+more|see\s+more|view\s+more|show\s+full(\s+job)?\s+description|see\s+full\s+description|expand)\s*(…|\.\.\.|[+▾▼›»>])?\s*$/i;
    const sleep = ms => new Promise(r => setTimeout(r, ms));
    const visible = el => { const r = el.getBoundingClientRect(); return r.width > 1 && r.height > 1 && getComputedStyle(el).visibility !== 'hidden'; };
    const safeLink = a => {
      if (a.tagName !== 'A') return true;
      const h = (a.getAttribute('href') || '').trim();
      if (!h || h === '#' || h.startsWith('#') || h.startsWith('javascript:')) return true;
      try { const u = new URL(a.href, location.href); return u.origin + u.pathname + u.search === location.origin + location.pathname + location.search; } catch (e) { return false; }
    };
    const clicked = new Set();
    let count = 0;
    for (let round = 0; round < 4; round++) {
      document.querySelectorAll('details:not([open])').forEach(d => { d.open = true; });
      const cands = [...document.querySelectorAll('button, a, [role="button"], summary, span[tabindex], div[tabindex]')]
        .filter(el => !clicked.has(el) && visible(el) && !el.closest('nav, header, footer, [role="navigation"], [role="banner"], [role="contentinfo"]'))
        .filter(el => { const t = (el.innerText || el.textContent || el.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim(); return t.length < 60 && MORE.test(t); })
        .filter(safeLink);
      if (!cands.length) break;
      for (const el of cands) { clicked.add(el); try { el.click(); count++; } catch (e) {} }
      await sleep(900);
    }
    // Per CSS gekürzte Textblöcke (max-height / line-clamp) öffnen
    for (const el of document.querySelectorAll('main *, article *, [class*="job" i] *, [class*="description" i], [class*="content" i]')) {
      const cs = getComputedStyle(el);
      const clamp = cs.webkitLineClamp && cs.webkitLineClamp !== 'none';
      if ((clamp || (cs.maxHeight !== 'none' && (cs.overflowY === 'hidden' || cs.overflow === 'hidden')))
          && el.scrollHeight > el.clientHeight + 30 && (el.innerText || '').length > 200) {
        el.style.setProperty('max-height', 'none', 'important');
        el.style.setProperty('height', 'auto', 'important');
        el.style.setProperty('overflow', 'visible', 'important');
        el.style.setProperty('-webkit-line-clamp', 'unset', 'important');
        el.style.setProperty('mask-image', 'none', 'important');
        el.style.setProperty('-webkit-mask-image', 'none', 'important');
      }
    }
    return count;
    """#

    /// true, solange im Hauptdokument noch ein sichtbarer Consent-Banner steht.
    static let consentVisible = #"""
    (() => {
      if (document.documentElement.getAttribute('data-sa-consent') === 'open') return true;
      const sel = 'bahf-cd-modal.modal-open, #onetrust-banner-sdk, #onetrust-consent-sdk .otPcCenter, #usercentrics-root, #usercentrics-cmp-ui, #CybotCookiebotDialog, #didomi-popup, #didomi-notice, [id^="sp_message_container"], #cmpbox, .fc-consent-root, .cc-window, #BorlabsCookieBox ._brlbs-bar, .klaro .cookie-notice, iframe[src*="privacy-mgmt"], iframe[src*="consent"]';
      for (const el of document.querySelectorAll(sel)) {
        const r = el.getBoundingClientRect();
        if (r.width > 50 && r.height > 50 && getComputedStyle(el).display !== 'none' && getComputedStyle(el).visibility !== 'hidden') {
          if (el.id === 'usercentrics-root') {
            const sr = el.shadowRoot;
            if (sr && [...sr.querySelectorAll('button')].some(b => b.getBoundingClientRect().width > 0)) return true;
            continue;
          }
          return true;
        }
      }
      return false;
    })();
    """#
}

//
//  CDPSession+Scripts.swift
//  BrowserTools
//
//  JavaScript extraction scripts evaluated by CDPSession for consent dialogs,
//  search results, page content and dynamic scrolling.
//

import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - JavaScript extraction scripts

extension CDPSession {
    /// Clicks "Accept all" / "I agree" consent buttons (multi-language).
    static let googleConsentClickJS = #"""
(() => {
const clean=s=>(s||'').replace(/\s+/g,' ').trim();
const pats=[/accept all/i,/i agree/i,/agree/i,/accetta tutto/i,/tout accepter/i,/aceptar todo/i,/alle akzeptieren/i];
const els=[...document.querySelectorAll('button,[role=button],input[type=submit],a')];
for (const el of els){const t=clean(el.innerText||el.value||el.textContent);
if(!t)continue; if(pats.some(p=>p.test(t))){el.click(); return 'clicked '+t;}}
return '';
})()
"""#

    /// Extracts Google search results as markdown: visible links + text snapshot.
    static let extractSearchJS = #"""
(() => {
const clean=s=>(s||'').replace(/\s+/g,' ').trim();
const esc=s=>clean(s).replace(/\\/g,'\\\\').replace(/\[/g,'\\[').replace(/\]/g,'\\]').replace(/\n/g,' ');
const visible=el=>{const r=el.getBoundingClientRect();const st=getComputedStyle(el);return r.width>0&&r.height>0&&st.display!=='none'&&st.visibility!=='hidden'&&st.opacity!=='0';};
const bad=h=>(/(^|\.)google\./.test(h)||/(^|\.)gstatic\./.test(h)||/(^|\.)googleusercontent\./.test(h));
const lines=['# Google search results','',`URL: ${location.href}`,'','## Visible links'];
const seen=new Set();
for(const a of document.querySelectorAll('a[href]')){if(!visible(a))continue;let href=a.href||'';
try{const u=new URL(href);if(u.pathname==='/url'&&u.searchParams.get('q'))href=u.searchParams.get('q');}catch{}
let u;try{u=new URL(href);}catch{continue;}if(!/^https?:$/.test(u.protocol))continue;if(bad(u.hostname))continue;
const text=esc(a.innerText||a.textContent);if(text.length<3)continue;if(seen.has(u.href))continue;seen.add(u.href);
lines.push(`- [${text.slice(0,180)}](${u.href})`);if(seen.size>=20)break;}
lines.push('','## Text snapshot',clean(document.body.innerText).slice(0,1200));
return lines.join('\n');
})()
"""#

    /// Extracts page content as markdown: headings, paragraphs, lists, code,
    /// blockquotes, comments, and visible links.
    static let extractPageJS = #"""
(() => {
const clean=s=>(s||'').replace(/\s+/g,' ').trim();
const esc=s=>clean(s).replace(/\\/g,'\\\\').replace(/\[/g,'\\[').replace(/\]/g,'\\]').replace(/\n/g,' ');
const visible=el=>{const r=el.getBoundingClientRect();const st=getComputedStyle(el);return r.width>0&&r.height>0&&st.display!=='none'&&st.visibility!=='hidden'&&st.opacity!=='0';};
const inline=n=>{if(!n)return'';if(n.nodeType===3)return n.nodeValue;if(n.nodeType!==1)return'';const el=n;
if(el.tagName==='SCRIPT'||el.tagName==='STYLE'||el.tagName==='NOSCRIPT')return'';
if(el.tagName==='A'){const t=esc(el.innerText||el.textContent);const h=el.href||'';return t&&h?`[${t}](${h})`:t;}
if(el.tagName==='CODE')return '`'+clean(el.innerText||el.textContent).replace(/`/g,'\\`')+'`';
return [...el.childNodes].map(inline).join('');};
const lines=[`# ${clean(document.title)||location.href}`,'',`URL: ${location.href}`,'','## Content'];
const blocks=[...document.body.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th,[id="content-text"],[class*="comment-body"],[class*="comment-content"],[data-testid*="comment-text"]')];
const seen=new Set();let joinedLength=lines.reduce((a,l)=>a+l.length,0)+lines.length-1;
for(const el of blocks){if(!visible(el))continue;let s='';const tag=el.tagName;
if(/^H[1-6]$/.test(tag)){s='#'.repeat(Number(tag[1]))+' '+inline(el);}
else if(tag==='LI'){s='- '+inline(el);}
else if(tag==='PRE'){s='```\n'+(el.innerText||el.textContent||'').trimEnd()+'\n```';}
else if(tag==='BLOCKQUOTE'){s='> '+clean(el.innerText||el.textContent);}
else{s=inline(el);}s=s.trim();if(!s||seen.has(s))continue;seen.add(s);lines.push('',s);joinedLength+=2+s.length;
if(joinedLength>900000){lines.push('','[Content truncated by browser extractor.]');break;}}
lines.push('','## Visible links');let n=0;const linkSeen=new Set();
for(const a of document.querySelectorAll('a[href]')){if(!visible(a))continue;const t=esc(a.innerText||a.textContent);if(t.length<3)continue;
let u;try{u=new URL(a.href);}catch{continue;}if(!/^https?:$/.test(u.protocol)||linkSeen.has(u.href))continue;linkSeen.add(u.href);
lines.push(`- [${t.slice(0,160)}](${u.href})`);if(++n>=80)break;}
return lines.join('\n');
})()
"""#

    /// Scrolls the page incrementally to load lazy/infinite content. Returns a
    /// Promise that resolves when scrolling is exhausted.
    static let dynamicScrollJS = #"""
(() => new Promise(resolve => {
const root=()=>document.scrollingElement||document.documentElement||document.body;
const blockSel='h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th,[id="content-text"],[class*="comment-body"],[class*="comment-content"],[data-testid*="comment-text"]';
const lazySel='[onscroll],[loading="lazy"],[data-src],[data-lazy],[class*="lazy"],[class*="infinite"],[class*="virtual"],[role="feed"],[id*="comment"],[class*="comment"],[data-testid*="comment"]';
const hookCount=()=>{let n=0;try{if(window.onscroll)n++;if(document.onscroll)n++;if(document.body&&document.body.onscroll)n++;}catch(e){}
try{if(typeof getEventListeners==='function'){for(const o of [window,document,document.body]){if(!o)continue;const ev=getEventListeners(o);if(ev&&ev.scroll)n+=ev.scroll.length;}}}catch(e){}
try{n+=document.querySelectorAll(lazySel).length;}catch(e){}return n;};
const metrics=()=>{const r=root();return {
height:r?r.scrollHeight:0,
view:innerHeight||900,
y:scrollY||(r&&r.scrollTop)||0,
text:((document.body&&document.body.innerText)||'').length,
links:document.links?document.links.length:0,
blocks:document.body?document.body.querySelectorAll(blockSel).length:0,
hooks:hookCount()};};
const sig=m=>[m.height,m.text,m.links,m.blocks].join('|');
const grew=(a,b)=>b.height>a.height+20||b.text>a.text+200||b.links>a.links+2||b.blocks>a.blocks+2;
const scrollOnce=()=>{const r=root();if(!r)return;
const h=Math.max(700,Math.floor((innerHeight||900)*0.85));
window.scrollTo(0,Math.min(r.scrollHeight,(scrollY||r.scrollTop||0)+h));};
let last=metrics(),lastSig=sig(last),same=0,steps=0;
const scrollable=last.height>last.view*1.35;
if(!scrollable||last.hooks===0){resolve('scroll skipped hooks='+last.hooks+' text='+last.text);return;}
const tick=()=>{
if(steps>=28){resolve('scrolled '+steps+' text='+last.text);return;}
const before=last;
scrollOnce();steps++;
setTimeout(()=>{const now=metrics(),nowSig=sig(now);
if(nowSig===lastSig)same++;else same=0;
const loaded=grew(before,now);
last=now;lastSig=nowSig;
if(steps===1&&!loaded){resolve('scroll probe unchanged text='+now.text);return;}
const atBottom=now.y+now.view+20>=now.height;
if(same>=4||(atBottom&&same>=1)){resolve('scrolled '+steps+' text='+now.text);return;}
tick();},900);
};tick();
}))()
"""#
}

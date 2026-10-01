// Website contact details (phone, e-mail, address). The super admin edits
// them in the dashboard ("Холбоо барих", schema_v43); this puts the current
// ones into the page. What is written in the HTML stays as the fallback, so
// the page is complete even if this request fails.
//   data-c-text="phone|email|address"  -> text
//   data-c-href="phone|email"          -> tel: / mailto: link
//   data-c-show="address"              -> shown only when there is a value
(function(){
  var API='https://oxfbxqclqfglpzgzizhq.supabase.co/rest/v1/site_settings?id=eq.1&select=phone,email,address';
  var KEY='sb_publishable_W3WMWLP28Czb2_5VTDQUlg_--3vfY71';      // public key, the same as in config.js
  function tel(p){ var d=String(p||'').replace(/[^\d+]/g,''); if(!d) return ''; if(d.charAt(0)!=='+') d=(d.length===8?'+976':'')+d; return 'tel:'+d; }
  function apply(c){
    if(!c||!c.phone||!c.email) return;
    window.ytContacts=c;
    document.querySelectorAll('[data-c-text]').forEach(function(el){ var v=c[el.getAttribute('data-c-text')]; if(v) el.textContent=v; });
    document.querySelectorAll('[data-c-href]').forEach(function(el){ el.href = el.getAttribute('data-c-href')==='phone' ? tel(c.phone) : 'mailto:'+c.email; });
    document.querySelectorAll('[data-c-show]').forEach(function(el){ el.hidden=!c[el.getAttribute('data-c-show')]; });
    var ld=document.querySelector('script[type="application/ld+json"]');
    if(ld){ try{ var j=JSON.parse(ld.textContent); if(j.contactPoint){ j.contactPoint.telephone=tel(c.phone).slice(4); j.contactPoint.email=c.email; ld.textContent=JSON.stringify(j); } }catch(e){} }
    try{ window.dispatchEvent(new Event('yt:contacts')); }catch(e){}
  }
  try{ apply(JSON.parse(localStorage.getItem('yt-contacts')||'null')); }catch(e){}
  if(!window.fetch) return;
  fetch(API,{headers:{apikey:KEY,Authorization:'Bearer '+KEY}})
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(rows){ var c=rows&&rows[0]; if(c){ apply(c); try{ localStorage.setItem('yt-contacts',JSON.stringify(c)); }catch(e){} } })
    .catch(function(){});
})();

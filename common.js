function $(id){return document.getElementById(id)}
function esc(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]))}
function money(v){return '₹'+Number(v||0).toLocaleString('en-IN',{maximumFractionDigits:2})}
function showMsg(el,msg,error=false){if(el){el.textContent=msg;el.classList.toggle('error',!!error)}}
function localDate(){const d=new Date();return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`}
function toggleTheme(){const dark=document.documentElement.getAttribute('data-theme')==='dark';const next=dark?'light':'dark';document.documentElement.setAttribute('data-theme',next);localStorage.setItem('praksh-theme',next);const b=$('theme');if(b)b.textContent=next==='dark'?'☀':'☾'}
(function(){const saved=localStorage.getItem('praksh-theme');if(saved)document.documentElement.setAttribute('data-theme',saved)})();

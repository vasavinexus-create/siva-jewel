import { mount,db,shop,field,usernameField,form,result,escape,cursorList,fetchCursor,selectShop } from '../app.js';
import { loginDomain, usernamePattern } from '../supabase/functions/_shared/login.js';

const passwordField=(label,required=false)=>'<div class="owner-password">'+
  field('password',label,'type="password" minlength="6" autocomplete="new-password"'+(required?' required':''))+
  '<button type="button" data-toggle-password>Show password</button></div>';
const adminFields=()=>usernameField('Shop administrator username')+
  passwordField('Shop administrator password',true);
const logoField=()=>field('logo','Shop logo (optional)','type="file" accept="image/png,image/jpeg,image/webp"');

async function prepareLogo(file){
  if(!file?.size) return null;
  if(!['image/png','image/jpeg','image/webp'].includes(file.type) || file.size>5*1024*1024){
    throw new Error('Choose a PNG, JPEG, or WebP logo up to 5 MB.');
  }
  const image=await createImageBitmap(file).catch(()=>{throw new Error('Could not read the logo image.');});
  try {
    const scale=Math.min(1,128/Math.max(image.width,image.height));
    const canvas=document.createElement('canvas');
    canvas.width=Math.max(1,Math.round(image.width*scale));
    canvas.height=Math.max(1,Math.round(image.height*scale));
    canvas.getContext('2d').drawImage(image,0,0,canvas.width,canvas.height);
    return canvas.toDataURL('image/png');
  } finally {
    image.close();
  }
}

async function saveAdministrator(details){
  const {data,error}=await db.functions.invoke('create-staff',{body:{...details,admin:true}});
  if(!error) return data;
  const response=await error.context?.json?.().catch(()=>null);
  throw new Error(response?.error || error.message);
}

mount('owner',async()=>{
  const main=document.querySelector('main');
  const tabs=[['create-shop','Create shop'],['manage-shops','Manage shops'],['administrators','Administrators']];
  main.insertAdjacentHTML('beforeend','<div class="owner-tabs" role="tablist" aria-label="Owner tools">'+
    tabs.map(([id,label])=>'<button type="button" role="tab" id="tab-'+id+'" aria-controls="'+id+'">'+label+'</button>').join('')+
    '</div>'+tabs.map(([id])=>'<div role="tabpanel" id="'+id+'" aria-labelledby="tab-'+id+'" hidden></div>').join(''));
  const tabButtons=[...main.querySelectorAll('[role=tab]')];
  const activate=(id,focus=false)=>{
    for(const button of tabButtons){
      const active=button.getAttribute('aria-controls')===id;
      button.setAttribute('aria-selected',String(active));
      button.tabIndex=active?0:-1;
      document.getElementById(button.getAttribute('aria-controls')).hidden=!active;
      if(active&&focus) button.focus();
    }
    history.replaceState(null,'','#'+id);
  };
  const requested=location.hash.slice(1);
  activate(tabs.some(([id])=>id===requested)?requested:'manage-shops');
  tabButtons.forEach((button,index)=>{
    button.onclick=()=>activate(tabs[index][0]);
    button.onkeydown=event=>{
      const next={ArrowLeft:(index+tabs.length-1)%tabs.length,ArrowRight:(index+1)%tabs.length,Home:0,End:tabs.length-1}[event.key];
      if(next===undefined) return;
      event.preventDefault();
      activate(tabs[next][0],true);
    };
  });

  main.addEventListener('click',event=>{
    const toggle=event.target.closest('[data-toggle-password]');
    if(!toggle) return;
    const input=toggle.closest('.owner-password').querySelector('input');
    const show=input.type==='password';
    input.type=show?'text':'password';
    toggle.textContent=show?'Hide password':'Show password';
  });

  form(field('shopName','Shop name')+logoField()+adminFields(),'Create shop',async ({logo,...data})=>{
    const added=await saveAdministrator({...data,logo:await prepareLogo(logo)});
    activate('manage-shops');
    selectShop(added.shopId);
  },false,document.querySelector('#create-shop'));

  const administrators=document.querySelector('#administrators');
  const loadAdministrators=async()=>{
    if(!shop){
      administrators.textContent='Create a shop to manage its administrators.';
      return;
    }
    const [selected,members]=await Promise.all([
      result(db.from('shops').select('name').eq('id',shop).single()),
      result(db.from('staff').select('user_id,email').eq('shop_id',shop).contains('pages',['admin']).order('email')),
    ]);
    administrators.innerHTML='<h2>'+escape(selected.name)+'</h2>';
    form(adminFields(),'Create shop administrator',data=>saveAdministrator({...data,shop}),true,administrators);
    for(const member of members){
      const username=member.email?.endsWith('@'+loginDomain)?member.email.slice(0,-loginDomain.length-1):'';
      form(field('username','Shop administrator username',
        'required pattern="'+usernamePattern+'" autocomplete="off" value="'+escape(username)+'"')+
        passwordField('New password (leave blank to keep current password)'),
        'Save administrator login',data=>saveAdministrator({...data,shop,administratorId:member.user_id}),true,administrators);
    }
    if(!members.length) administrators.insertAdjacentHTML('beforeend','<p>This shop has no administrator.</p>');
  };

  const shopList=cursorList(document.querySelector('#manage-shops'),cursor=>fetchCursor(db.from('shops').select('id,name,paused'),
    [['name',true],['id',true]],cursor),(shops,container)=>{
    if(!shops.length) container.textContent='No shops yet. Use Create shop to add one.';
    for(const item of shops){
      const editor=form('<strong>'+escape(item.name)+(item.id===shop?' (selected)':'')+'</strong>'+
        '<button type="button" data-admins>Manage administrators</button>',
        item.paused?'Resume shop':'Pause shop',async()=>{
          await result(db.from('shops').update({paused:!item.paused}).eq('id',item.id));
        },true,container);
      editor.querySelector('[data-admins]').onclick=()=>{
        activate('administrators');
        if(item.id!==shop) selectShop(item.id);
      };
      const edit=document.createElement('details');
      edit.innerHTML='<summary>Edit shop</summary>';
      form(field('name','Shop name','required value="'+escape(item.name)+'"')+logoField(),'Save shop',async ({name,logo})=>{
        const trimmed=name.trim();
        if(!trimmed) throw new Error('Enter a shop name.');
        const image=await prepareLogo(logo);
        await result(db.from('shops').update({name:trimmed,...(image?{logo:image}:{})}).eq('id',item.id).select('id').single());
      },true,edit);
      editor.after(edit);
    }
  });
  await Promise.all([shopList,loadAdministrators()]);
});

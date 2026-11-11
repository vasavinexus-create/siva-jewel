import { mount,db,shop,field,usernameField,form,result,escape,section,cursorList,fetchCursor,selectShop } from '../app.js';

const adminFields=()=>usernameField('Shop administrator username')+
  field('password','Shop administrator password','type="password" minlength="6" autocomplete="new-password" required');
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

async function createAdministrator(details){
  const {data,error}=await db.functions.invoke('create-staff',{body:{...details,admin:true}});
  if(!error) return data;
  const response=await error.context?.json?.().catch(()=>null);
  throw new Error(response?.error || error.message);
}

mount('owner',async()=>{
  form(field('shopName','Shop name')+logoField()+adminFields(),'Create shop',async ({logo,...data})=>{
    const added=await createAdministrator({...data,logo:await prepareLogo(logo)});
    selectShop(added.shopId);
  },false);
  if(shop) form(adminFields(),'Create shop admin for selected shop',data=>createAdministrator({...data,shop}));
  section('<div id="shops"></div>');
  await cursorList(document.querySelector('#shops'),cursor=>fetchCursor(db.from('shops').select('id,name,paused'),
    [['name',true],['id',true]],cursor),(shops,container)=>{
    for(const item of shops){
      const editor=form('<strong>'+escape(item.name)+(item.id===shop?' (selected)':'')+'</strong>'+
        '<button type="button" data-select>Select shop</button>',item.paused?'Resume shop':'Pause shop',async()=>{
          await result(db.from('shops').update({paused:!item.paused}).eq('id',item.id));
        },true,container);
      const select=editor.querySelector('[data-select]');
      select.disabled=item.id===shop;
      select.onclick=()=>selectShop(item.id);
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
});

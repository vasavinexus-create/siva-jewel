import { mount,db,shop,field,usernameField,form,result,escape,section,cursorList,fetchCursor,selectShop } from '../app.js';

const adminFields=()=>usernameField('Shop administrator username')+
  field('password','Shop administrator password','type="password" minlength="6" autocomplete="new-password" required');

async function createAdministrator(details){
  const {data,error}=await db.functions.invoke('create-staff',{body:{...details,admin:true}});
  if(!error) return data;
  const response=await error.context?.json?.().catch(()=>null);
  throw new Error(response?.error || error.message);
}

mount('owner',async()=>{
  form(field('shopName','Shop name')+adminFields(),'Create shop',async data=>{
    const added=await createAdministrator(data);
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
      form(field('name','Shop name','required value="'+escape(item.name)+'"'),'Save shop name',async ({name})=>{
        const trimmed=name.trim();
        if(!trimmed) throw new Error('Enter a shop name.');
        await result(db.from('shops').update({name:trimmed}).eq('id',item.id).select('id').single());
      },true,edit);
      editor.after(edit);
    }
  });
});

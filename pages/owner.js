import { mount,db,shop,field,usernameField,form,result,escape,section,cursorList,fetchCursor,selectShop } from '../app.js';

mount('owner',async()=>{
  form(field('name','Shop name'),'Add shop',async data=>{
    const added=await result(db.from('shops').insert(data).select('id').single());
    selectShop(added.id);
  },false);
  if(shop) form(usernameField('Shop administrator username')+field('password','Temporary password','type="password" minlength="12" required'),
    'Create shop admin for selected shop',data=>result(db.functions.invoke('create-staff',{body:{...data,shop,admin:true}})));
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
    }
  });
});

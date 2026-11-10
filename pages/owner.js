import { mount,db,shop,shops,field,usernameField,form,result,escape } from '../app.js';

mount('owner',async()=>{
    form(field('name','Shop name'),'Add shop',async data=>{await result(db.from('shops').insert(data)); location.reload();},false);
    for(const item of shops){
      form('<strong>'+escape(item.name)+'</strong>',item.paused?'Resume shop':'Pause shop',async()=>{
        await result(db.from('shops').update({paused:!item.paused}).eq('id',item.id)); location.reload();
      },false);
    }
    if(shop) form(usernameField('Shop administrator username')+field('password','Temporary password','type="password" minlength="12" required'),
      'Create shop admin',data=>result(db.functions.invoke('create-staff',{body:{...data,shop,admin:true}})));
});

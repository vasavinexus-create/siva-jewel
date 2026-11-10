import { mount,db,shop,labels,permissions,escape,field,usernameField,form,result,pageOffset,pageLinks } from '../app.js';
import { loginDomain } from '../supabase/functions/_shared/login.js';

mount('admin',async()=>{
    const offset=pageOffset();
    const staff=await result(db.from('staff').select('user_id,email,pages')
      .eq('shop_id',shop).not('pages','cs','{admin}').order('user_id').range(offset,offset+50));
    const checks = selected => permissions.map(p=>'<label><span><input name="'+p+'" type="checkbox" '+(selected.includes(p)?'checked':'')+'> '+escape(labels[p]||'Shop sign-in')+'</span></label>').join('');
    const selected = data => permissions.filter(p=>data[p]);
    form(usernameField('Staff username')+field('password','Temporary password','type="password" minlength="12" required')+checks([]),
      'Create staff',data=>result(db.functions.invoke('create-staff',{body:{username:data.username,password:data.password,shop,pages:selected(data)}})));
    for(const member of staff.slice(0,50)){
      form('<strong>'+escape(member.email?.replace('@'+loginDomain,'') || member.user_id)+'</strong>'+checks(member.pages),'Save access',data=>result(db.from('staff').update({pages:selected(data)}).eq('shop_id',shop).eq('user_id',member.user_id)));
    }
    pageLinks(offset,staff.length>50);
});

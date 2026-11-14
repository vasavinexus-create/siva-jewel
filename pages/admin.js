import { mount,db,shop,labels,permissions,escape,field,usernameField,form,result,section,run,lookupField,searchLookup } from '../app.js';
import { loginDomain } from '../supabase/functions/_shared/login.js';

mount('admin',async()=>{
    const editModes = {pledge_edit_all:'Can edit all pledge details',pledge_edit_details:'Can edit non-financial details only'};
    const checks = selected => permissions.map(p=>'<label><span><input name="'+p+'" type="checkbox" '+(selected.includes(p)?'checked':'')+'> '+escape(labels[p])+'</span></label>').join('')+
      '<label>Pledge loan editing<select name="pledge_edit"><option value="">View only</option>'+
      Object.entries(editModes).map(([key,label])=>'<option value="'+key+'" '+(selected.includes(key)?'selected':'')+'>'+label+'</option>').join('')+
      '</select></label><label><span><input type="checkbox" name="customer_edit" '+
      (selected.includes('customer_edit')?'checked':'')+'> Can edit customers</span></label>';
    const selected = data => ['shop', ...permissions.filter(p=>data[p]),
      ...(data.loans && Object.hasOwn(editModes,data.pledge_edit)?[data.pledge_edit]:[]),
      ...(data.customers && data.customer_edit?['customer_edit']:[])];
    async function saveLogin(body) {
      const {error}=await db.functions.invoke('create-staff',{body:{shop,...body}});
      if(error){
        const payload=await error.context?.json?.().catch(()=>null);
        throw new Error(payload?.error||error.message);
      }
    }
    section('<div class="owner-tabs" role="tablist" aria-label="Staff users">'+
      '<button type="button" role="tab" id="create-user-tab" aria-controls="new-staff" aria-selected="true">Create user</button>'+
      '<button type="button" role="tab" id="edit-user-tab" aria-controls="existing-staff" aria-selected="false" tabindex="-1">Edit user</button></div>'+
      '<div id="new-staff" role="tabpanel" aria-labelledby="create-user-tab"></div>'+
      '<div id="existing-staff" role="tabpanel" aria-labelledby="edit-user-tab" hidden>'+
      '<form id="staff-picker">'+lookupField('staff_id','Staff user','Type a username')+
      '<button type="submit" disabled>Edit selected user</button></form><div id="staff-editor"></div></div>');
    const tabs=[document.querySelector('#create-user-tab'),document.querySelector('#edit-user-tab')];
    const activate=active=>{
      for(const tab of tabs){
        tab.setAttribute('aria-selected',String(tab===active));
        tab.tabIndex=tab===active?0:-1;
        document.getElementById(tab.getAttribute('aria-controls')).hidden=tab!==active;
      }
    };
    tabs.forEach((tab,index)=>{
      tab.onclick=()=>activate(tab);
      tab.onkeydown=event=>{
        const next={ArrowLeft:1-index,ArrowRight:1-index,Home:0,End:1}[event.key];
        if(next===undefined) return;
        event.preventDefault();
        activate(tabs[next]);
        tabs[next].focus();
      };
    });
    form(usernameField('Staff username')+field('password','Temporary password','type="password" minlength="6" required autocomplete="new-password"')+checks([]),
      'Create staff',data=>saveLogin({username:data.username,password:data.password,pages:selected(data)}),true,document.querySelector('#new-staff'));

    const picker=document.querySelector('#staff-picker');
    const staffId=picker.elements.staff_id;
    const editButton=picker.querySelector('button');
    const container=document.querySelector('#staff-editor');
    const usernameOf=member=>member.email?.replace('@'+loginDomain,'')||'';
    const staffQuery=()=>db.from('staff').select('user_id,email,pages').eq('shop_id',shop).not('pages','cs','{admin}');
    staffId.onchange=()=>{
      editButton.disabled=!staffId.value;
      container.replaceChildren();
    };
    searchLookup(picker,'staff_id',async term=>(await result(staffQuery()
      .ilike('email',term.replace(/[\\%_]/g,'\\$&')+'%').order('email').order('user_id').limit(20)))
      .map(member=>({...member,id:member.user_id})),usernameOf);
    picker.onsubmit=run(async event=>{
      event.preventDefault();
      const id=staffId.value;
      const member=await result(staffQuery().eq('user_id',id).single());
      if(staffId.value!==id) return;
      const currentUsername=usernameOf(member);
      container.replaceChildren();
      const credentials=form(usernameField('Username')+
        field('password','New password','type="password" minlength="6" autocomplete="new-password"')+
        '<p>Leave the password blank to keep the current password.</p>','Save login',async(data,editor)=>{
          const username=data.username.toLowerCase();
          const changed=username!==editor.elements.username.defaultValue;
          if(!changed&&!data.password) return;
          await saveLogin({staffId:id,password:data.password,...(changed?{username}:{})});
          editor.elements.username.defaultValue=username;
          editor.elements.password.value='';
          if(staffId.value===id) picker.querySelector('[role=combobox]').value=username;
          document.querySelector('#message').textContent='Login updated.';
        },false,container);
      credentials.elements.username.defaultValue=currentUsername;
      form(checks(member.pages),'Save access',async data=>{
        await result(db.from('staff').update({pages:selected(data)}).eq('shop_id',shop).eq('user_id',id).select('user_id').single());
        document.querySelector('#message').textContent='Access updated.';
      },false,container);
    });
});

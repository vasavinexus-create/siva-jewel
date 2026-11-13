import { mount,db,field,usernameField,form,result,navigate } from '../app.js';
import { loginEmail } from '../supabase/functions/_shared/login.js';

mount('login',async()=>{
    form(usernameField('Username')+field('password','Password','type="password" required autocomplete="current-password"'),'Sign in',async data=>{
      const email=loginEmail(data.username);
      if(!email) throw new Error('Enter a valid username.');
      await result(db.auth.signInWithPassword({email,password:data.password})); navigate('unassigned');
    },false);
    document.querySelector('main').insertAdjacentHTML('beforeend',`
      <aside class="login-provider" aria-labelledby="login-provider-label">
        <p id="login-provider-label">PledgePilot software provider</p>
        <img src="./vasavi-nexus-logo.jpeg" width="1272" height="909"
          alt="Vasavi Nexus — Smart Business Operating Platform. We provide wings to your business.">
      </aside>
    `);
});

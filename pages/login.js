import { mount,db,field,usernameField,form,result,navigate } from '../app.js';
import { loginEmail } from '../supabase/functions/_shared/login.js';

mount('login',async()=>{
    form(usernameField('Username')+field('password','Password','type="password" required autocomplete="current-password"'),'Sign in',async data=>{
      const email=loginEmail(data.username);
      if(!email) throw new Error('Enter a valid username.');
      await result(db.auth.signInWithPassword({email,password:data.password})); navigate('unassigned');
    },false);
});

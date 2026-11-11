import { mount,db,shop,escape,field,option,today,table,result,form,run } from '../app.js';

const kinds=['Day book','Pledging','Releases','Profit and loss','Balance sheet','Trial balance','General ledger','Loan balance'];

mount('reports', () => {
  let reportVersion=0;
  const filters=form('<label>Report<select name="kind">'+kinds.map(kind=>option(kind,kind)).join('')+'</select></label>'+
    field('from','From','type="date"')+field('to','Through','type="date" value="'+today()+'"'),'Run report',async ({kind,from,to})=>{
    const version=++reportVersion;
    const output=document.querySelector('#report');
    const cursors=[null];
    let summary;
    const show=async index=>{
      const page=await result(db.rpc('run_report',{
        s:shop,kind,from_date:from||null,to_date:to||null,page_cursor:cursors[index]
      }));
      if(version!==reportVersion) return;
      summary=page.summary??summary;
      cursors[index+1]=page.next_cursor;
      output.innerHTML='<h2>'+escape(page.title)+'</h2>'+
        (summary?'<p>'+escape(summary)+'</p>':'')+table(page.headers,page.rows);
      if(index===0&&!page.next_cursor) return;
      output.insertAdjacentHTML('beforeend','<p><button type="button" data-prev>Previous</button> <span>Page '+
        (index+1)+'</span> <button type="button" data-next>Next</button></p>');
      const previous=output.querySelector('[data-prev]');
      const next=output.querySelector('[data-next]');
      previous.disabled=index===0;
      next.disabled=!page.next_cursor;
      const move=destination=>run(async()=>{
        previous.disabled=true;
        next.disabled=true;
        try {await show(destination);}
        finally {previous.disabled=index===0;next.disabled=!page.next_cursor;}
      });
      previous.onclick=move(index-1);
      next.onclick=move(index+1);
    };
    output.replaceChildren();
    await show(0);
  },false);
  filters.insertAdjacentHTML('afterend','<section id="report"></section>');
});

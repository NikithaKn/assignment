import { Component, OnInit } from '@angular/core';
import { ProjService } from '../../services/proj.service';

@Component({
  selector: 'app-suggested-proj',
  templateUrl: './suggested-proj.component.html',
  styleUrls: ['./suggested-proj.component.css']
})
export class SuggestedProjComponent implements OnInit {

  imageResp = [];
  i=0;
  imgPath;
  constructor(private service :ProjService ) { }
 
  ngOnInit() {
    this.service.getImages().subscribe( (resp:any) => {
       
      for(let i = 0 ; i <= 10 ; i++ ){
           this.imageResp.push(resp[i].url);
      } 
      this.imgPath = this.imageResp[0];
    })
    
  }

 next(){
  this.i++;
   this.imgPath= this.imageResp[this.i];
  
    if(this.i>=10){
        this.i=0;
    };
};

prev(){
  this.i--;
   this.imgPath= this.imageResp[this.i];
    
    if(this.i>=10){
        this.i=0;
    };
};


}

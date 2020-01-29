import { Component, OnInit } from '@angular/core';
import { ProjService } from '../../services/proj.service';

@Component({
  selector: 'app-activity',
  templateUrl: './activity.component.html',
  styleUrls: ['./activity.component.css']
})
export class ActivityComponent implements OnInit {

  listData = [];
  constructor(private service :ProjService) { }

  ngOnInit() {
      this.service.getImages().subscribe( (resp:any) => {
       for(let i =0; i< 25 ; i++){
         this.listData.push(resp[i])
       }
      })
  }

}

import { BrowserModule } from '@angular/platform-browser';
import { NgModule } from '@angular/core';

import { AppRoutingModule } from './app-routing.module';
import { AppComponent } from './app.component';
import { BrowserAnimationsModule } from '@angular/platform-browser/animations';
import {MatMenuModule } from '@angular/material/menu';
import { HttpClientModule } from '@angular/common/http'
import { SuggestedProjComponent } from './suggested-proj/suggested-proj.component';
import { ProjService } from '../services/proj.service';
import { ActivityComponent } from './activity/activity.component';
import { ChartsModule } from 'ng2-charts';
import { ChartComponent } from './chart/chart.component';

@NgModule({
  declarations: [
    AppComponent,
    SuggestedProjComponent,
    ActivityComponent,
    ChartComponent
  ],
  imports: [
    BrowserModule,
    AppRoutingModule,
    BrowserAnimationsModule,
    MatMenuModule ,
    MatMenuModule,
    HttpClientModule,
    ChartsModule
  ],
  providers: [ProjService],
  bootstrap: [AppComponent]
})
export class AppModule { }

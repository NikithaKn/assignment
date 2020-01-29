

import { Injectable } from '../../node_modules/@angular/core';
import { HttpClient } from '@angular/common/http';
 

@Injectable ({
    providedIn:'root'
})

export class ProjService {

    constructor(private http:HttpClient) {

    }
    getImages(){
        const url = 'https://jsonplaceholder.typicode.com/photos';
        return this.http.get(url);
    }
}
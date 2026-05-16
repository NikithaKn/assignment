import { async, ComponentFixture, TestBed } from '@angular/core/testing';

import { SuggestedProjComponent } from './suggested-proj.component';

describe('SuggestedProjComponent', () => {
  let component: SuggestedProjComponent;
  let fixture: ComponentFixture<SuggestedProjComponent>;
  // KAN-10: Added comment for 6th test ticket
  beforeEach(async(() => {
    TestBed.configureTestingModule({
      declarations: [ SuggestedProjComponent ]
    })
    .compileComponents();
  }));

  beforeEach(() => {
    fixture = TestBed.createComponent(SuggestedProjComponent);
    component = fixture.componentInstance;
    fixture.detectChanges();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });
});

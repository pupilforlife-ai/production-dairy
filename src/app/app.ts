import { Component } from '@angular/core';
import { RouterOutlet } from '@angular/router';
import { environment } from '../environment';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  readonly betaMode = environment.betaMode;
}

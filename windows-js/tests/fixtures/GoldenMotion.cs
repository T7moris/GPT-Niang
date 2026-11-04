using System;using System.Collections.Generic;using System.Web.Script.Serialization;
public static class GoldenMotion {
 public static void Main(){var rows=new List<object>();foreach(double dpi in new double[]{1,1.25,1.5}){var m=new GptMusicMotion(350*dpi,400*dpi,1000*dpi,700*dpi,118*dpi,dpi);for(int i=0;i<900;i++){
  double dt=new double[]{1.0/60,.012,.018,.15,.033}[i%5];if(i==100)m.BeginHold(320*dpi,240*dpi);if(i>100&&i<=130)m.MoveHeld((320+(i-100)*7)*dpi,(260-Math.Sin(i*.11)*80)*dpi,dt,(320+(i-100)*7)*dpi,(240-Math.Sin(i*.11)*80)*dpi);if(i==131)m.Release();if(i==500)m.Resize(1250*dpi,740*dpi,140*dpi,dpi);
  bool locked=i>220&&(i<600||i>650);m.Step(dt,i>=300&&i<332,locked,i*.016/.52,.52,.93,dt);if(!locked&&i>220)m.RespondToOnset((i%40)*.016,.9);
  rows.Add(new{dpi=dpi,i=i,m.X,m.Y,m.Vx,m.Vy,m.Bend,m.BendSpeed,m.Rock,m.RockSpeed,m.Lamp,m.LampSpeed,m.Props,m.Phase,m.Impacts,m.Cycle,m.Energy,m.Held,m.ThrowX,m.ThrowY,m.ReleaseIdleMs});
 }}Console.WriteLine(new JavaScriptSerializer(){MaxJsonLength=16000000}.Serialize(rows));}
}

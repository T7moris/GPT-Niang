using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Automation;
using System.Text.RegularExpressions;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
// Windows interoperability only. UI and state remain JavaScript.
public static class GptNativeBridge {
 static readonly object Gate=new object();static readonly JavaScriptSerializer Json=new JavaScriptSerializer();static GptMusicCapture capture;static bool running=true;
 static readonly object ProbeGate=new object();static Task<bool> pendingProbe;static IntPtr pendingTarget;
 static bool Poll(IntPtr handle){lock(ProbeGate){
  if(handle==IntPtr.Zero)return false;
  if(pendingProbe!=null&&!pendingProbe.IsCompleted)return false;
  bool ready=pendingProbe!=null&&pendingTarget==handle&&pendingProbe.Status==TaskStatus.RanToCompletion&&pendingProbe.Result;
  pendingTarget=handle;pendingProbe=Task.Factory.StartNew(()=>Ready(handle),CancellationToken.None,TaskCreationOptions.LongRunning,TaskScheduler.Default);
  return ready;
 }}
 static void Send(object value){lock(Gate){Console.WriteLine(Json.Serialize(value));Console.Out.Flush();}}
 public static void Main(string[] args){
  if(args.Length==2&&args[0]=="--decode-bmp"){
   var decode=new Thread(delegate(){try{DecodeBitmap(args[1]);}catch(Exception e){Console.Error.WriteLine(e.Message);Environment.ExitCode=1;}});
   decode.SetApartmentState(ApartmentState.STA);decode.Start();decode.Join();
   return;
  }
  var timer=new Timer(delegate{GptMusicCapture c=capture;if(c!=null){try{Send(new{type="audio",nowMs=GptMusicCapture.NowMs,snapshot=c.Snapshot()});}catch{}}},null,0,16);
  try{string line;while(running&&(line=Console.ReadLine())!=null){try{var q=Json.Deserialize<Dictionary<string,object>>(line);var op=Convert.ToString(q["op"],CultureInfo.InvariantCulture);
   if(op=="start"){if(capture==null)capture=new GptMusicCapture(true);}
   else if(op=="stop"){var old=capture;capture=null;if(old!=null)old.Dispose();}
   else if(op=="probe"){long h=Convert.ToInt64(q["handle"],CultureInfo.InvariantCulture);object id=q["id"];Send(new{type="ready",id=id,handle=h,ready=Poll(new IntPtr(h))});}
  }catch(Exception e){Send(new{type="error",error=e.Message});}}}finally{running=false;timer.Dispose();if(capture!=null)capture.Dispose();}
 }
 static void DecodeBitmap(string file){
  using(var stream=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read)){
   if(stream.Length==0||stream.Length>20L*1024*1024)throw new Exception("Invalid BMP file size");
   var decoder=BitmapDecoder.Create(stream,BitmapCreateOptions.PreservePixelFormat,BitmapCacheOption.OnDemand);
   if(!(decoder is BmpBitmapDecoder)||decoder.Frames.Count==0)throw new Exception("Invalid BMP image");
   var frame=decoder.Frames[0];int width=frame.PixelWidth,height=frame.PixelHeight;
   if(width<1||height<1||width>4096||height>4096||(long)width*height>16000000)throw new Exception("BMP image is too large");
   var converted=new FormatConvertedBitmap(frame,PixelFormats.Bgra32,null,0);int stride=checked(width*4);var pixels=new byte[checked(stride*height)];converted.CopyPixels(pixels,stride,0);
   var image=BitmapSource.Create(width,height,96,96,PixelFormats.Bgra32,null,pixels,stride);
   var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(image));
   using(var encoded=new MemoryStream()){encoder.Save(encoded);encoded.Position=0;using(var output=Console.OpenStandardOutput()){encoded.CopyTo(output);output.Flush();}}
  }
 }
 static bool Ready(IntPtr handle){try{
  var root=AutomationElement.FromHandle(handle);var usable=new AndCondition(new PropertyCondition(AutomationElement.IsEnabledProperty,true),new PropertyCondition(AutomationElement.IsOffscreenProperty,false));
  if(root.FindFirst(TreeScope.Descendants,new AndCondition(usable,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Edit)))!=null)return true;
  var buttons=root.FindAll(TreeScope.Descendants,new AndCondition(usable,new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.Button)));
  for(int i=0;i<buttons.Count;i++)if(Regex.IsMatch(buttons[i].Current.Name??"",@"^(new (thread|chat|conversation)|settings|\u65b0\u7ebf\u7a0b|\u65b0\u5efa\u7ebf\u7a0b|\u65b0\u5bf9\u8bdd|\u65b0\u5efa\u5bf9\u8bdd|\u8bbe\u7f6e)(\s|$)",RegexOptions.IgnoreCase))return true;
 }catch{}return false;}
}

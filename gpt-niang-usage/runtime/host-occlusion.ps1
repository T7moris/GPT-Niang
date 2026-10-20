Add-Type -AssemblyName WindowsBase
if(!('GptWidgetOcclusionRecovery' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

// Experimental owner-preserving compatibility controller. Only its own HWND
// is mutated. Ordinary timers are stopped after a short event-settling burst.
public sealed class GptCloakTransition {
 public bool Active {get;private set;}
 public bool Cloaked {get;private set;}
 long deadline,stableSince;
 bool? previous;
 public void Begin(long now){if(Active)return;Active=true;deadline=now+256;previous=null;stableSince=now;}
 public int Sample(long now,bool covered){
  if(!Active)return 0;
  if(previous!=covered){previous=covered;stableSince=now;}
  int action=0;
  if(covered&&!Cloaked){Cloaked=true;action=1;}
  if(!covered&&Cloaked&&(now-stableSince>=32||now>=deadline)){Cloaked=false;action=-1;}
  // Foreground notifications can precede actual Z-order changes. Do not stop
  // just because the first two snapshots agree; retain the short burst until
  // a real restoration was emitted, or its fixed budget expires.
  if(action==-1||now>=deadline)Active=false;
  return action;
 }
 public void Stop(){Active=false;Cloaked=false;previous=null;}
}

public sealed class GptWidgetOcclusionRecovery:IDisposable {
 [StructLayout(LayoutKind.Sequential)]struct Rect{public int left,top,right,bottom;}
 [StructLayout(LayoutKind.Sequential)]struct WindowPosition{public IntPtr hwnd,after;public int x,y,width,height;public uint flags;}
 [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")]static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("user32.dll")]static extern IntPtr GetAncestor(IntPtr h,uint flags);
 [DllImport("user32.dll")]static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")]static extern IntPtr GetLong(IntPtr h,int index);
 [DllImport("user32.dll")]static extern bool GetLayeredWindowAttributes(IntPtr h,out uint key,out byte alpha,out uint flags);
 [DllImport("user32.dll")]static extern int GetWindowRgn(IntPtr h,IntPtr region);
 [DllImport("gdi32.dll")]static extern IntPtr CreateRectRgn(int left,int top,int right,int bottom);
 [DllImport("gdi32.dll")]static extern int GetRgnBox(IntPtr region,out Rect bounds);
 [DllImport("gdi32.dll")]static extern bool DeleteObject(IntPtr region);
 [DllImport("dwmapi.dll")]static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out uint value,int size);
 [DllImport("dwmapi.dll")]static extern int DwmSetWindowAttribute(IntPtr h,int attribute,ref int value,int size);
 readonly IntPtr widget;
 readonly uint ownPid;
 readonly DispatcherTimer timer;
 readonly DispatcherTimer watch;
 readonly GptCloakTransition transition=new GptCloakTransition();
 IntPtr host;
 bool enabled,disposed,failed,ownedCloak,changing;
 public long Checks {get;private set;}
 public double TotalCheckMs {get;private set;}
 public double MaxCheckMs {get;private set;}
 public long Toggles {get;private set;}
 public int LastHresult {get;private set;}
 public double LastToggleQpc {get;private set;}
 public bool Pending {get{return timer.IsEnabled;}}
 public bool OwnedCloak {get{return ownedCloak;}}
 public bool Failed {get{return failed;}}
 static long Now(){return Stopwatch.GetTimestamp()*1000/Stopwatch.Frequency;}
 public GptWidgetOcclusionRecovery(IntPtr widget){
  uint actual;GetWindowThreadProcessId(widget,out actual);
  ownPid=(uint)Process.GetCurrentProcess().Id;
  if(!IsWindow(widget)||actual!=ownPid)throw new ArgumentException("Recovery may only mutate its own window");
  this.widget=widget;
  uint initial;LastHresult=DwmGetWindowAttribute(widget,14,out initial,4);
  if(LastHresult!=0||(initial&1)!=0)failed=true;
  timer=new DispatcherTimer(DispatcherPriority.Background);
  timer.Interval=TimeSpan.FromMilliseconds(32);timer.Tick+=OnTick;
  // A covering window can close or hide without leaving any WinEvent behind.
  // Keep one low-frequency safety recheck while our own window is cloaked so a
  // stale cloak can never outlive its covering window.
  watch=new DispatcherTimer(DispatcherPriority.Background);
  watch.Interval=TimeSpan.FromMilliseconds(500);watch.Tick+=OnWatch;
 }
 public void Configure(IntPtr host,bool enabled){
  if(disposed)return;
  if(this.host==host&&this.enabled==enabled)return;
  this.enabled=false;Restore();this.host=host;this.enabled=enabled;
  Begin();
 }
 public void OnWindowEvent(IntPtr hwnd){
  if(hwnd==IntPtr.Zero||GetAncestor(hwnd,2)!=hwnd)return;
  Begin();
 }
 public void OnPositionChanged(IntPtr data){
  if(data==IntPtr.Zero)return;
  var position=(WindowPosition)Marshal.PtrToStructure(data,typeof(WindowPosition));
  // Windows also reorders owned windows during host promotion. Observe that
  // completion through our own HWND; geometry-only updates need no new burst.
  if(position.hwnd==widget&&(position.flags&4)==0)Begin();
 }
 void Begin(){
  if(disposed||failed||changing||!enabled||host==IntPtr.Zero||timer.IsEnabled)return;
  watch.Stop();
  transition.Begin(Now());Step();
  if(transition.Active)timer.Start();
 }
 void OnTick(object sender,EventArgs args){Step();if(!transition.Active){timer.Stop();ScheduleWatch();}}
 void OnWatch(object sender,EventArgs args){
  watch.Stop();
  if(disposed||failed||changing||!enabled||host==IntPtr.Zero||!ownedCloak)return;
  transition.Begin(Now());Step();
  if(transition.Active)timer.Start();
 }
 void ScheduleWatch(){
  if(disposed||failed||changing||!enabled||!ownedCloak||watch.IsEnabled)return;
  watch.Start();
 }
 void Step(){
  if(disposed||failed||!enabled||!IsWindow(host)||!IsWindow(widget)||!IsWindowVisible(host)||IsIconic(host)){Restore();return;}
  long started=Stopwatch.GetTimestamp();bool? covered=FullyCovered();Checks++;
  double elapsed=(Stopwatch.GetTimestamp()-started)*1000.0/Stopwatch.Frequency;
  TotalCheckMs+=elapsed;if(elapsed>MaxCheckMs)MaxCheckMs=elapsed;
  if(!covered.HasValue){Restore();return;}
  int action=transition.Sample(Now(),covered.Value);
  if(action!=0&&!SetOwnCloak(action>0)){failed=true;Restore();}
 }
 bool SetOwnCloak(bool value){
  if(ownedCloak==value)return true;
  uint actual;GetWindowThreadProcessId(widget,out actual);
  if(actual!=ownPid||!IsWindow(widget))return false;
  int flag=value?1:0;changing=true;
  try{LastHresult=DwmSetWindowAttribute(widget,13,ref flag,4);}finally{changing=false;}
  if(LastHresult!=0)return false;
  ownedCloak=value;Toggles++;LastToggleQpc=(double)Stopwatch.GetTimestamp()/Stopwatch.Frequency;
  return true;
 }
 void Restore(){timer.Stop();watch.Stop();transition.Stop();if(ownedCloak)SetOwnCloak(false);}
 static bool Contains(Rect outer,Rect inner){return outer.left<=inner.left&&outer.top<=inner.top&&outer.right>=inner.right&&outer.bottom>=inner.bottom;}
 bool? FullyCovered(){
  Rect target;if(!GetWindowRect(host,out target)||target.right<=target.left||target.bottom<=target.top)return null;
  IntPtr h=GetWindow(host,3);int count=0;
  while(h!=IntPtr.Zero&&count++<200){
   uint pid;GetWindowThreadProcessId(h,out pid);
   if(h!=widget&&pid!=ownPid&&IsWindowVisible(h)&&!IsIconic(h)){
    long ex=GetLong(h,-20).ToInt64();uint cloak;
    Rect bounds;
    if((ex&0xA0)==0&&DwmGetWindowAttribute(h,14,out cloak,4)==0&&cloak==0&&GetWindowRect(h,out bounds)&&Contains(bounds,target)){
     bool opaque=true;
     if((ex&0x80000)!=0){uint key,flags;byte alpha;opaque=GetLayeredWindowAttributes(h,out key,out alpha,out flags)&&(flags&1)==0&&((flags&2)==0||alpha==255);}
     if(opaque){
      IntPtr region=CreateRectRgn(0,0,0,0);
      if(region==IntPtr.Zero)return null;
      try{
       int type=GetWindowRgn(h,region);
       if(type==0)return true;
       if(type==2){Rect r;if(GetRgnBox(region,out r)==2){r.left+=bounds.left;r.right+=bounds.left;r.top+=bounds.top;r.bottom+=bounds.top;if(Contains(r,target))return true;}}
      }finally{DeleteObject(region);}
     }
    }
   }
   h=GetWindow(h,3);
  }
  if(h!=IntPtr.Zero)return null;
  return false;
 }
 public void Dispose(){if(disposed)return;disposed=true;enabled=false;Restore();timer.Tick-=OnTick;watch.Tick-=OnWatch;}
}

'@ -ReferencedAssemblies ([Windows.Threading.DispatcherTimer].Assembly.Location)
}

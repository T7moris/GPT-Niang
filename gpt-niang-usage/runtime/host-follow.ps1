if(!('GptWidgetHostFollower' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Keep movement in the native event callback. Calling PowerShell or waiting for
// a DispatcherTimer here makes a separate transparent window trail its host.
public sealed class GptWidgetHostFollower : IDisposable {
 [StructLayout(LayoutKind.Sequential)] struct Rect {public int Left,Top,Right,Bottom;}
 [StructLayout(LayoutKind.Sequential)] struct MonitorInfo {public int Size;public Rect Monitor,Work;public uint Flags;}
 [StructLayout(LayoutKind.Sequential)] struct Point {public int X,Y;}
 [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point point,uint flags);
 [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr h);
 [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h,uint flags);
 [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor,ref MonitorInfo info);
 delegate void WinEventProc(IntPtr hook,uint ev,IntPtr hwnd,int objectId,int childId,uint threadId,uint time);
 [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint first,uint last,IntPtr module,WinEventProc callback,uint processId,uint threadId,uint flags);
 [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int z,uint flags);
 [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint processId);
 [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h,IntPtr region,bool redraw);
 [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int left,int top,int right,int bottom);
 [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr value);
 readonly IntPtr widget;
 readonly WinEventProc callback;
 IntPtr host,locationHook,lifecycleHook;
 int insetLeft,insetTop,insetRight,insetBottom,width,height,left,right,bottom;
 int hostWidth,hostHeight,clipLeft=-1,clipTop=-1,clipWidth=-1,clipHeight=-1;
 uint hostDpi;
 IntPtr selectedMonitor;
 string anchor;
 bool enabled,hiddenByHost,disposed;
 int temporaryX,temporaryY;
 int[] characterBounds;
 IntPtr companion;
 int companionWidth,companionHeight,companionTop;
 public long MovementEvents {get;private set;}
 public long PositionChanges {get;private set;}
 public uint MaxDeliveryMs {get;private set;}
 public uint LastDeliveryMs {get;private set;}
 public bool LayoutDirty {get;private set;}
 public Action LayoutRequested;
 public bool Moving {get;private set;}
 public bool Ready {get{return locationHook!=IntPtr.Zero;}}
 public GptWidgetHostFollower(IntPtr widget){this.widget=widget;callback=OnEvent;}
 public static int[] VisibleBounds(IntPtr host,int left,int top,int right,int bottom){
  return Clip(MonitorFromWindow(host,2),left,top,right,bottom);
 }
 public static int[] VisibleBoundsAt(int left,int top,int right,int bottom,int x,int y){
  return Clip(MonitorFromPoint(new Point{X=x,Y=y},2),left,top,right,bottom);
 }
 static int[] Clip(IntPtr monitor,int left,int top,int right,int bottom){
  var info=new MonitorInfo();info.Size=Marshal.SizeOf(typeof(MonitorInfo));
  if(GetMonitorInfo(monitor,ref info)){
   int l=Math.Max(left,info.Work.Left),t=Math.Max(top,info.Work.Top);
   int r=Math.Min(right,info.Work.Right),b=Math.Min(bottom,info.Work.Bottom);
   if(r>l&&b>t)return new[]{l,t,r,b};
   return new[]{info.Work.Left,info.Work.Top,info.Work.Right,info.Work.Bottom};
  }
  return new[]{left,top,right,bottom};
 }

 public void Configure(IntPtr host,int frameLeft,int frameTop,int frameRight,int frameBottom,
                       int width,int height,int left,int right,int bottom,string anchor,bool enabled,int[] characterBounds=null){
  if(disposed)return;
  bool changedHost=this.host!=host;
  if(changedHost){
   ReleaseHooks();this.host=host;Moving=false;hiddenByHost=false;
   if(IsWindow(host)){
    uint processId;GetWindowThreadProcessId(host,out processId);
    locationHook=SetWinEventHook(0x800B,0x800B,IntPtr.Zero,callback,processId,0,0);
    lifecycleHook=SetWinEventHook(0x10,0x17,IntPtr.Zero,callback,processId,0,0);
   }
  }
  Rect r;
  if(GetWindowRect(host,out r)){
   if(changedHost||!Moving){
    // Reject a mixed snapshot if the host moved between the frame and HWND reads.
    int il=frameLeft-r.Left,it=frameTop-r.Top,ir=r.Right-frameRight,ib=r.Bottom-frameBottom;
    if(il>=0&&il<=32&&it>=0&&it<=32&&ir>=0&&ir<=32&&ib>=0&&ib<=32){
     insetLeft=il;insetTop=it;insetRight=ir;insetBottom=ib;
    }
   }
   hostWidth=r.Right-r.Left;hostHeight=r.Bottom-r.Top;hostDpi=GetDpiForWindow(host);selectedMonitor=IntPtr.Zero;LayoutDirty=false;
  }
  this.width=width;this.height=height;this.left=left;this.right=right;
  this.bottom=bottom;this.anchor=anchor;this.enabled=enabled;
  this.characterBounds=characterBounds!=null&&characterBounds.Length==4?(int[])characterBounds.Clone():null;
  if(enabled)Synchronize();
 }
 public void Suspend(){enabled=false;}
 public void SetTemporaryOffset(int x,int y){temporaryX=x;temporaryY=y;SynchronizeCore(true);}
 // A decorative companion shares this same host snapshot and native move event.
 // Its coordinates are never clamped to the desktop work area.
 public void SetCompanion(IntPtr handle,int width,int height,int top){
  if(companion==handle&&companionWidth==width&&companionHeight==height&&companionTop==top)return;
  companion=handle;companionWidth=width;companionHeight=height;companionTop=top;Synchronize();
 }
 public int[] GetFrame(){
  Rect r;if(!GetWindowRect(host,out r))return null;
  return new[]{r.Left+insetLeft,r.Top+insetTop,r.Right-insetRight,r.Bottom-insetBottom};
 }
 public void Detach(){
  enabled=false;ReleaseHooks();host=IntPtr.Zero;Moving=false;hiddenByHost=false;
  clipLeft=-1;clipTop=-1;clipWidth=-1;clipHeight=-1;SetWindowRgn(widget,IntPtr.Zero,true);
 }
 void OnEvent(IntPtr hook,uint ev,IntPtr hwnd,int objectId,int childId,uint threadId,uint time){
  if(disposed||hwnd!=host||objectId!=0||childId!=0)return;
  if(ev==0x10)Moving=true;
  if(ev==0x11)Moving=false;
  if(ev==0x800B){
   MovementEvents++;
   uint delay=unchecked((uint)Environment.TickCount-time);LastDeliveryMs=delay;
   if(delay>MaxDeliveryMs)MaxDeliveryMs=delay;
  }
  Synchronize();
 }
 public bool Synchronize(){return SynchronizeCore(false);}
 bool SynchronizeCore(bool musicMove){
  if(disposed||!enabled||!IsWindow(host)||!IsWindow(widget))return false;
  if(!IsWindowVisible(host)||IsIconic(host)){
   if(companion!=IntPtr.Zero)ShowWindow(companion,0);
   ShowWindow(widget,0);hiddenByHost=true;return false;
  }
  Rect frame,current;if(!GetWindowRect(host,out frame))return false;
  uint dpi=GetDpiForWindow(host);
  if(frame.Right-frame.Left<64*Math.Max(1,dpi/96.0)||frame.Bottom-frame.Top<64*Math.Max(1,dpi/96.0)){ShowWindow(widget,0);hiddenByHost=true;return false;}
  if(!LayoutDirty&&(dpi!=hostDpi||frame.Right-frame.Left!=hostWidth||frame.Bottom-frame.Top!=hostHeight)){
   LayoutDirty=true;if(LayoutRequested!=null)LayoutRequested();
  }
  frame.Left+=insetLeft;frame.Top+=insetTop;frame.Right-=insetRight;frame.Bottom-=insetBottom;
  if(companion!=IntPtr.Zero&&IsWindow(companion)){
   int cx=frame.Left+(frame.Right-frame.Left-companionWidth)/2,cy=frame.Top+companionTop;
   Rect c;if(!GetWindowRect(companion,out c)||c.Left!=cx||c.Top!=cy)
    SetWindowPos(companion,IntPtr.Zero,cx,cy,0,0,0x215);
  }
  int px=anchor=="right"?frame.Right-width-right:frame.Left+left;
  int py=frame.Bottom-height-bottom;
  if(characterBounds!=null){
   // Resize constrains only the character, preserving flush edges and the
   // requested offsets. Translation off screen still uses the full host frame.
   int minX=frame.Left-characterBounds[0],maxX=frame.Right-characterBounds[2];
   px=maxX<minX?(int)Math.Round((minX+(double)maxX)/2):Math.Max(minX,Math.Min(maxX,px));
   py=Math.Max(frame.Top-characterBounds[1],Math.Min(frame.Bottom-characterBounds[3],py));
  }
  IntPtr monitor=MonitorFromPoint(new Point{X=px+temporaryX+width/2,Y=py+temporaryY+height/2},2);
  if(selectedMonitor!=IntPtr.Zero&&monitor!=selectedMonitor&&!LayoutDirty){LayoutDirty=true;if(LayoutRequested!=null)LayoutRequested();}
  selectedMonitor=monitor;
  // Position follows the full host frame. The work area only clips pixels.
  int x=px+temporaryX,y=py+temporaryY;
  var bounds=Clip(monitor,frame.Left,frame.Top,frame.Right,frame.Bottom);
  int cl=Math.Max(0,Math.Max(frame.Left,bounds[0])-x);
  int ct=Math.Max(0,Math.Max(frame.Top,bounds[1])-y);
  int cr=Math.Min(width,Math.Min(frame.Right,bounds[2])-x);
  int cb=Math.Min(height,Math.Min(frame.Bottom,bounds[3])-y);
  int cw=Math.Max(0,cr-cl),ch=Math.Max(0,cb-ct);
  if(cw==0||ch==0){cl=0;ct=0;cw=0;ch=0;}
  if(cl!=clipLeft||ct!=clipTop||cw!=clipWidth||ch!=clipHeight){
   IntPtr region=CreateRectRgn(cl,ct,cl+cw,ct+ch);
   if(region!=IntPtr.Zero){
    if(SetWindowRgn(widget,region,true)!=0){clipLeft=cl;clipTop=ct;clipWidth=cw;clipHeight=ch;}
    else DeleteObject(region);
   }
  }
  if(!GetWindowRect(widget,out current)||current.Left!=x||current.Top!=y){
   // Position only: WPF owns size and rendering. No resize, activation or
   // z-order changes, and no queued asynchronous SetWindowPos operation.
   // Music changes position only. Avoid WPF synchronously disabling its
   // render target for WM_WINDOWPOSCHANGING; WM_WINDOWPOSCHANGED still arrives.
   // Ordinary host synchronization retains its original notification path.
   if(!SetWindowPos(widget,IntPtr.Zero,x,y,0,0,musicMove?0x415u:0x15u))return false;
   PositionChanges++;
  }
  if(hiddenByHost){ShowWindow(widget,4);hiddenByHost=false;}
  return true;
 }
 void ReleaseHooks(){
  if(locationHook!=IntPtr.Zero){UnhookWinEvent(locationHook);locationHook=IntPtr.Zero;}
  if(lifecycleHook!=IntPtr.Zero){UnhookWinEvent(lifecycleHook);lifecycleHook=IntPtr.Zero;}
 }
 public void Dispose(){if(disposed)return;disposed=true;enabled=false;ReleaseHooks();GC.KeepAlive(callback);}
}
'@
}

function Update-WidgetCharacterGallery {
  if(!$script:characterGallery){return}
  $gallery=$script:characterGallery;$cards=$gallery.FindName('CharacterCards');$cards.Children.Clear()
  foreach($character in @(Get-WidgetCharacters $script:appDir $script:dataDir)){
    $card=[Windows.Controls.Grid]::new();$card.Tag=$character.id;$card.Height=216;$card.Margin=[Windows.Thickness]::new(0,0,12,12)
    $button=[Windows.Controls.Button]::new();$button.Style=$gallery.Resources['CharacterCard'];$button.Tag=$character.id;$button.ToolTip=$character.name
    if($character.id-eq $script:characterId){
      $button.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#EEE2F8')
      $button.BorderBrush=[Windows.Media.BrushConverter]::new().ConvertFromString('#A483C5')
    }
    $panel=[Windows.Controls.StackPanel]::new()
    $preview=[Windows.Controls.Image]::new();$preview.Height=128;$preview.Stretch=[Windows.Media.Stretch]::Uniform
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($preview,[Windows.Media.BitmapScalingMode]::HighQuality)
    try{$preview.Source=Read-WidgetCharacterImage $character.path}catch{$button.IsEnabled=$false}
    $panel.Children.Add($preview)|Out-Null
    $title=[Windows.Controls.TextBlock]::new();$title.Text=$character.name;$title.FontSize=14.5;$title.FontWeight=[Windows.FontWeights]::SemiBold
    $title.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$title.Margin=[Windows.Thickness]::new(0,10,0,5)
    $title.TextTrimming=[Windows.TextTrimming]::CharacterEllipsis;$title.MaxWidth=190;$panel.Children.Add($title)|Out-Null
    $detail=[Windows.Controls.TextBlock]::new();$detail.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$detail.FontSize=11.5
    $detail.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#917BA1')
    $detail.Text=if(!$button.IsEnabled){'图片不可用'}elseif($character.id-eq $script:characterId){'✓ 当前使用'}elseif($character.kind-eq 'custom'){'我的导入'}else{'内置角色'}
    $panel.Children.Add($detail)|Out-Null;$button.Content=$panel
    $button.Add_Click({param($sender,$event)
      try{$null=Set-WidgetCharacter ([string]$sender.Tag);Update-WidgetSettingsMenu;$script:characterGallery.Close()}
      catch{if($script:characterGallery){$script:characterGallery.FindName('CharacterFeedback').Text=$_.Exception.Message}}
      $event.Handled=$true
    })
    $card.Children.Add($button)|Out-Null
    if($character.kind-eq 'custom'){
      $remove=[Windows.Controls.Button]::new();$remove.Style=$gallery.Resources['GalleryIcon'];$remove.Content=New-WidgetGalleryIcon 'remove';$remove.Tag=$character.id;$remove.Uid='remove'
      $remove.ToolTip='移除导入的角色';$remove.HorizontalAlignment=[Windows.HorizontalAlignment]::Right;$remove.VerticalAlignment=[Windows.VerticalAlignment]::Top
      $remove.Margin=[Windows.Thickness]::new(0,7,7,0)
      [Windows.Automation.AutomationProperties]::SetName($remove,('移除 '+$character.name))
      $remove.Add_Click({param($sender,$event)
        try{Remove-WidgetGalleryCharacter ([string]$sender.Tag)}catch{$script:characterGallery.FindName('CharacterFeedback').Text=$_.Exception.Message}
        $event.Handled=$true
      })
      $card.Children.Add($remove)|Out-Null
    }
    $cards.Children.Add($card)|Out-Null
  }
  # The import entry always follows every available character.
  $addCard=[Windows.Controls.Grid]::new();$addCard.Tag='add-character';$addCard.Height=216;$addCard.Margin=[Windows.Thickness]::new(0,0,12,12)
  $add=[Windows.Controls.Button]::new();$add.Style=$gallery.Resources['CharacterCard'];$add.Tag='add-character'
  $add.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#F5EFFA')
  $add.ToolTip='添加形象：PNG / JPG / BMP / GIF（第一帧）；上限 20 MB、4096 边长及 1600 万像素。'
  [Windows.Automation.AutomationProperties]::SetName($add,'添加形象')
  $addPanel=[Windows.Controls.StackPanel]::new();$addPanel.VerticalAlignment=[Windows.VerticalAlignment]::Center
  $circle=[Windows.Controls.Border]::new();$circle.Width=54;$circle.Height=54;$circle.CornerRadius=[Windows.CornerRadius]::new(27)
  $circle.Background=[Windows.Media.BrushConverter]::new().ConvertFromString('#EDE2F6');$circle.HorizontalAlignment=[Windows.HorizontalAlignment]::Center
  $plus=New-WidgetGalleryIcon 'add';$plus.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$plus.VerticalAlignment=[Windows.VerticalAlignment]::Center
  $circle.Child=$plus;$addPanel.Children.Add($circle)|Out-Null
  $caption=[Windows.Controls.TextBlock]::new();$caption.Text='添加形象';$caption.FontSize=14.5;$caption.FontWeight=[Windows.FontWeights]::SemiBold
  $caption.Foreground=[Windows.Media.BrushConverter]::new().ConvertFromString('#745A98');$caption.HorizontalAlignment=[Windows.HorizontalAlignment]::Center;$caption.Margin=[Windows.Thickness]::new(0,14,0,0)
  $addPanel.Children.Add($caption)|Out-Null;$add.Content=$addPanel
  $add.Add_Click({param($sender,$event)
    try{Open-WidgetCharacterPicker}catch{if($script:characterGallery){$script:characterGallery.FindName('CharacterFeedback').Text=$_.Exception.Message}}
    $event.Handled=$true
  })
  $addCard.Children.Add($add)|Out-Null;$cards.Children.Add($addCard)|Out-Null
  $removed=@(Get-WidgetRemovedCharacters $script:dataDir|Sort-Object removedAt)
  $script:galleryLastRemovedId=if($removed.Count){$removed[$removed.Count-1].id}else{$null}
  $gallery.FindName('UndoRemoval').Visibility=if($script:galleryLastRemovedId){[Windows.Visibility]::Visible}else{[Windows.Visibility]::Collapsed}
}

function New-WidgetGalleryIcon([ValidateSet('close','remove','add')][string]$Kind) {
  $icon=[Windows.Shapes.Path]::new();$icon.Width=12;$icon.Height=12;$icon.Stretch=[Windows.Media.Stretch]::None
  $icon.Stroke=[Windows.Media.BrushConverter]::new().ConvertFromString('#8461B0');$icon.StrokeThickness=1.6
  $icon.StrokeStartLineCap=[Windows.Media.PenLineCap]::Round;$icon.StrokeEndLineCap=[Windows.Media.PenLineCap]::Round
  $icon.IsHitTestVisible=$false
  $geometry=switch($Kind){'close'{'M2,2 L10,10 M10,2 L2,10'}'remove'{'M2,6 L10,6'}'add'{'M2,10 L18,10 M10,2 L10,18'}}
  if($Kind-eq 'add'){$icon.Width=20;$icon.Height=20;$icon.StrokeThickness=2}
  $icon.Data=[Windows.Media.Geometry]::Parse($geometry)
  return $icon
}

function Open-WidgetCharacterPicker {
  $picker=[Microsoft.Win32.OpenFileDialog]::new();$picker.Title='选择角色图片'
  $picker.Filter='角色图片 (*.png;*.jpg;*.jpeg;*.bmp;*.gif)|*.png;*.jpg;*.jpeg;*.bmp;*.gif';$picker.Multiselect=$false;$picker.CheckFileExists=$true
  if($picker.ShowDialog($script:characterGallery)-eq $true){Import-WidgetGalleryCharacter $picker.FileName}
}

function Remove-WidgetGalleryCharacter([string]$Id) {
  $previous=$script:characterId;$changed=$false
  try{
    # Save a working fallback before removing the currently displayed image.
    if($previous-eq $Id){$null=Set-WidgetCharacter 'gpt-dragon';$changed=$true}
    $removed=Remove-WidgetCharacter $script:dataDir $Id
  }catch{
    $failure=$_
    if($changed){try{$null=Set-WidgetCharacter $previous}catch{}}
    throw $failure
  }
  Update-WidgetCharacterGallery;Update-WidgetSettingsMenu
  $script:characterGallery.FindName('CharacterFeedback').Text='已移除 '+$removed.name+'，可随时撤销。'
}

function Import-WidgetGalleryCharacter([string]$SourcePath) {
  $imported=Import-WidgetCharacter $script:dataDir $SourcePath
  $null=Set-WidgetCharacter $imported.id
  Update-WidgetSettingsMenu
  $script:characterGallery.Close()
}

function Open-WidgetCharacterGallery {
  if($script:characterGallery -and $script:characterGallery.IsVisible){$script:characterGallery.Activate()|Out-Null;return}
  $gallery=[Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="GPT 娘 · 选择你喜欢的形象" Width="610" Height="560" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True"
 ShowInTaskbar="False" FontFamily="Microsoft YaHei UI" FontSize="14" Background="Transparent" WindowStartupLocation="CenterOwner">
 <Window.Resources>
  <Style x:Key="CharacterCard" TargetType="Button">
   <Setter Property="Background" Value="#FFFFFF"/><Setter Property="BorderBrush" Value="#E4DAEF"/><Setter Property="BorderThickness" Value="1.5"/>
   <Setter Property="Foreground" Value="#443552"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Padding" Value="14"/>
   <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="CardBody" CornerRadius="14" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}">
     <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
    </Border>
    <ControlTemplate.Triggers>
     <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="CardBody" Property="BorderBrush" Value="#A483C5"/></Trigger>
     <Trigger Property="IsPressed" Value="True"><Setter TargetName="CardBody" Property="Background" Value="#E9DCF4"/></Trigger>
     <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="CardBody" Property="BorderBrush" Value="#8461B0"/></Trigger>
     <Trigger Property="IsEnabled" Value="False"><Setter TargetName="CardBody" Property="Opacity" Value="0.55"/></Trigger>
    </ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="GalleryButton" TargetType="Button">
   <Setter Property="Foreground" Value="#745A98"/><Setter Property="Background" Value="#EEE5F6"/><Setter Property="BorderThickness" Value="0"/>
   <Setter Property="Cursor" Value="Hand"/><Setter Property="Padding" Value="13,8"/><Setter Property="FontSize" Value="12.5"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="ButtonBody" Background="{TemplateBinding Background}" CornerRadius="9" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBody" Property="Background" Value="#E4D7F0"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="GalleryIcon" TargetType="Button" BasedOn="{StaticResource GalleryButton}">
   <Setter Property="Width" Value="28"/><Setter Property="Height" Value="28"/><Setter Property="Padding" Value="0"/>
   <Setter Property="FontSize" Value="20"/><Setter Property="FontFamily" Value="Segoe UI"/><Setter Property="Background" Value="#F5EFFA"/>
  </Style>
  <Style x:Key="LavenderScrollThumb" TargetType="Thumb">
   <Setter Property="MinHeight" Value="28"/><Setter Property="Cursor" Value="Hand"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Thumb">
    <Border x:Name="ThumbBody" Background="#C6B0DD" CornerRadius="4" Margin="1,0"/>
    <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbBody" Property="Background" Value="#A98CC5"/></Trigger>
     <Trigger Property="IsDragging" Value="True"><Setter TargetName="ThumbBody" Property="Background" Value="#9170B5"/></Trigger></ControlTemplate.Triggers>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style TargetType="ScrollBar">
   <Setter Property="Width" Value="8"/><Setter Property="MinWidth" Value="8"/><Setter Property="MaxWidth" Value="8"/><Setter Property="Margin" Value="6,0,0,0"/>
   <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
    <Border Background="#F0E8F6" CornerRadius="4"><Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}">
     <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton>
     <Track.Thumb><Thumb Style="{StaticResource LavenderScrollThumb}"/></Track.Thumb>
     <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton>
    </Track></Border>
   </ControlTemplate></Setter.Value></Setter>
  </Style>
 </Window.Resources>
 <Border Background="#FAF8FD" BorderBrush="#DFD1EC" BorderThickness="1" CornerRadius="18" Padding="22,18,18,18">
  <Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
   <Grid Margin="0,0,0,18"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <Border x:Name="TitleDragArea" Background="Transparent" Cursor="SizeAll">
     <TextBlock Text="选择你喜欢的形象" FontSize="22" FontWeight="SemiBold" Foreground="#443552"/>
    </Border>
    <Button x:Name="CloseGallery" Grid.Column="1" Style="{StaticResource GalleryIcon}" VerticalAlignment="Center" ToolTip="关闭（Esc）"/>
   </Grid>
   <ScrollViewer x:Name="CharacterScroll" Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" CanContentScroll="False">
    <UniformGrid x:Name="CharacterCards" Columns="2" VerticalAlignment="Top"/>
   </ScrollViewer>
   <StackPanel Grid.Row="2" Margin="0,12,4,0">
    <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
     <TextBlock x:Name="CharacterFeedback" Foreground="#745A98" FontSize="12" VerticalAlignment="Center" TextWrapping="Wrap" Text="添加新形象时，推荐使用透明背景PNG"/>
     <Button x:Name="UndoRemoval" Grid.Column="1" Content="撤销移除" Style="{StaticResource GalleryButton}" Visibility="Collapsed" Margin="10,0,0,0"/>
    </Grid>
   </StackPanel>
  </Grid>
 </Border>
</Window>
'@)
  $gallery.Resources[[Windows.SystemParameters]::VerticalScrollBarWidthKey]=[double]8
  $gallery.FindName('CloseGallery').Content=New-WidgetGalleryIcon 'close'
  $script:characterGallery=$gallery;$gallery.Owner=$script:window;Update-WidgetCharacterGallery
  if($script:characterLoadNotice){$gallery.FindName('CharacterFeedback').Text=$script:characterLoadNotice}
  $gallery.FindName('TitleDragArea').Add_MouseLeftButtonDown({param($sender,$event)
    if($event.LeftButton-eq [Windows.Input.MouseButtonState]::Pressed){try{$script:characterGallery.DragMove()}catch{};$event.Handled=$true}
  })
  $gallery.FindName('UndoRemoval').Add_Click({
    try{
      $restored=Restore-WidgetCharacter $script:dataDir $script:galleryLastRemovedId
      Update-WidgetCharacterGallery;$script:characterGallery.FindName('CharacterFeedback').Text='已恢复 '+$restored.name+'，点选即可使用。'
    }catch{$script:characterGallery.FindName('CharacterFeedback').Text=$_.Exception.Message}
  })
  $gallery.FindName('CloseGallery').Add_Click({$script:characterGallery.Close()})
  $gallery.Add_KeyDown({param($sender,$event)if($event.Key-eq [Windows.Input.Key]::Escape){$sender.Close();$event.Handled=$true}})
  $gallery.Add_Closed({$script:characterGallery=$null})
  $gallery.Show()
}

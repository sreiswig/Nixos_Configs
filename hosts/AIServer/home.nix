{ ... }:

{
  # Keep the services box awake even if someone is logged into Plasma/XRDP.
  # systemd/logind already refuse suspend; this stops PowerDevil from asking.
  programs.plasma.powerdevil = {
    AC = {
      autoSuspend.action = "nothing";
      powerButtonAction = "nothing";
      whenLaptopLidClosed = "doNothing";
      turnOffDisplay.idleTimeout = "never";
      dimDisplay.enable = false;
      powerProfile = "performance";
    };
    battery = {
      autoSuspend.action = "nothing";
      powerButtonAction = "nothing";
      whenLaptopLidClosed = "doNothing";
      turnOffDisplay.idleTimeout = "never";
      dimDisplay.enable = false;
    };
    lowBattery = {
      autoSuspend.action = "nothing";
      powerButtonAction = "nothing";
      whenLaptopLidClosed = "doNothing";
      turnOffDisplay.idleTimeout = "never";
      dimDisplay.enable = false;
    };
  };
}

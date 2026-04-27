defmodule Gingko.CLI.PathsTest do
  use ExUnit.Case, async: true

  alias Gingko.CLI.Paths

  describe "classify_os/1" do
    test "maps darwin to :macos" do
      assert Paths.classify_os({:unix, :darwin}) == :macos
    end

    test "maps linux to :linux" do
      assert Paths.classify_os({:unix, :linux}) == :linux
    end

    test "maps any win32 family to :windows" do
      assert Paths.classify_os({:win32, :nt}) == :windows
      assert Paths.classify_os({:win32, :anything}) == :windows
    end

    test "everything else is :unsupported" do
      assert Paths.classify_os({:unix, :openbsd}) == :unsupported
      assert Paths.classify_os({:vxworks, :anything}) == :unsupported
    end
  end

  describe "service_unit_path/1" do
    test ":macos resolves to ~/Library/LaunchAgents/<label>.plist" do
      assert Paths.service_unit_path(:macos) ==
               Path.expand("~/Library/LaunchAgents/#{Paths.service_label()}.plist")
    end

    test ":unsupported raises" do
      assert_raise RuntimeError, fn -> Paths.service_unit_path(:unsupported) end
    end
  end

  describe "linux_systemd_unit_path/1" do
    test "honours XDG_CONFIG_HOME when set" do
      assert Paths.linux_systemd_unit_path("/tmp/xdg-config") ==
               "/tmp/xdg-config/systemd/user/gingko.service"
    end

    test "falls back to ~/.config when XDG_CONFIG_HOME is unset" do
      assert Paths.linux_systemd_unit_path(nil) ==
               Path.expand("~/.config/systemd/user/gingko.service")

      assert Paths.linux_systemd_unit_path("") ==
               Path.expand("~/.config/systemd/user/gingko.service")
    end
  end

  describe "windows_task_xml_path/1" do
    test "places the task XML under the resolved %LOCALAPPDATA%\\Gingko" do
      assert Paths.windows_task_xml_path("C:\\Users\\Test\\AppData\\Local") ==
               "C:\\Users\\Test\\AppData\\Local/Gingko\\gingko.task.xml"
    end

    test "falls back to %USERPROFILE%\\AppData\\Local when LOCALAPPDATA is unset" do
      expected_root = Path.join([System.user_home!(), "AppData", "Local"])

      assert Paths.windows_task_xml_path(nil) ==
               Path.join(expected_root, "Gingko\\gingko.task.xml")
    end
  end

  describe "log_dir/1" do
    test ":macos uses ~/Library/Logs/Gingko" do
      assert Paths.log_dir(:macos) == Path.expand("~/Library/Logs/Gingko")
    end

    test ":unsupported falls back to gingko_home/logs" do
      assert Paths.log_dir(:unsupported) == Path.join(Paths.gingko_home(), "logs")
    end
  end

  describe "linux_log_dir/1" do
    test "honours XDG_STATE_HOME when set" do
      assert Paths.linux_log_dir("/var/state") == "/var/state/gingko/logs"
    end

    test "falls back to ~/.local/state when XDG_STATE_HOME is unset" do
      assert Paths.linux_log_dir(nil) == Path.expand("~/.local/state/gingko/logs")
      assert Paths.linux_log_dir("") == Path.expand("~/.local/state/gingko/logs")
    end
  end

  describe "windows_log_dir/1" do
    test "places logs under %LOCALAPPDATA%\\Gingko\\logs" do
      assert Paths.windows_log_dir("C:\\Users\\Test\\AppData\\Local") ==
               "C:\\Users\\Test\\AppData\\Local/Gingko\\logs"
    end
  end

  describe "local_appdata/1" do
    test "returns the env value when set" do
      assert Paths.local_appdata("C:\\Users\\Test\\AppData\\Local") ==
               "C:\\Users\\Test\\AppData\\Local"
    end

    test "falls back to %USERPROFILE%\\AppData\\Local for nil and empty" do
      expected = Path.join([System.user_home!(), "AppData", "Local"])
      assert Paths.local_appdata(nil) == expected
      assert Paths.local_appdata("") == expected
    end
  end
end

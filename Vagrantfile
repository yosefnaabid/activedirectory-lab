Vagrant.configure("2") do |config|
  config.vm.box = "gusztavvargadr/windows-server-core"
  config.vm.box_check_update = false

  config.vm.communicator = "winrm"
  config.vm.boot_timeout = 600

  config.winrm.username = ENV.fetch("ADLAB_WINRM_USER", "vagrant")
  config.winrm.password = ENV.fetch("ADLAB_WINRM_PASS", "vagrant")

  config.vm.define "dc01" do |dc|
    dc.vm.hostname = "dc01"

    dc.vm.network "private_network", ip: "192.168.56.10"

    dc.vm.provider "virtualbox" do |vb|
      vb.name   = "ad-lab-dc01"
      vb.gui    = false
      vb.memory = 2048
      vb.cpus   = 2
    end

    dc.vm.provision "dc", type: "shell", path: "provision/01-controlador.ps1"

    dc.vm.provision "altas", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\scripts\usuarios.ps1 -Accion alta
    PS
    dc.vm.provision "estructura", type: "shell", run: "never", inline: <<-'PS'
      Copy-Item C:\vagrant\provision\*.ps1 C:\lab\provision\ -Force
      Copy-Item C:\vagrant\scripts\*      C:\lab\scripts\   -Force
      Copy-Item C:\vagrant\lab.psd1       C:\lab\           -Force
      & C:\lab\provision\02-estructura.ps1
    PS
    dc.vm.provision "informe", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\scripts\usuarios.ps1 -Accion informe
    PS
    dc.vm.provision "baja", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\scripts\usuarios.ps1 -Accion baja -Usuario amenendez
    PS

    dc.vm.provision "auditoria", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\scripts\auditoria.ps1
    PS
    dc.vm.provision "hardening", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\provision\03-seguridad.ps1
    PS

    dc.vm.provision "gpos", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\provision\04-gpos.ps1
    PS

    dc.vm.provision "dhcp", type: "shell", run: "never", inline: <<-'PS'
      if (Test-Path C:\vagrant\provision\06-dhcp.ps1) {
        Copy-Item C:\vagrant\provision\06-dhcp.ps1 C:\lab\provision\ -Force
        Copy-Item C:\vagrant\lab.psd1 C:\lab\ -Force
      }
      & C:\lab\provision\06-dhcp.ps1
    PS

    dc.vm.provision "eventos", type: "shell", run: "never", inline: <<-'PS'
      & C:\lab\scripts\Watch-ADSecurityEvents.ps1
    PS
  end

  config.vm.define "cli01", autostart: false do |cli|
    cli.vm.box = "gusztavvargadr/windows-11"
    cli.vm.communicator = "winrm"
    cli.vm.boot_timeout = 900
    cli.vm.hostname = "cli01"
    cli.vm.network "private_network", ip: "192.168.56.20"

    cli.winrm.username = "vagrant"
    cli.winrm.password = "vagrant"

    cli.vm.provider "virtualbox" do |vb|
      vb.name   = "ad-lab-cli01"
      vb.gui    = true
      vb.memory = 4096
      vb.cpus   = 2
    end

    cli.vm.provision "join", type: "shell", path: "provision/05-cliente.ps1",
                     args: ["192.168.56.10", "lab.local"]
  end
end

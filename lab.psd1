@{
    Dominio         = 'lab.local'
    NetBIOS         = 'LAB'
    NivelBosque     = 'WinThreshold'
    DsrmPassword    = 'LabDSRM.2026'
    PasswordInicial = 'Bienvenid@.2026'
    OU = @{
        Usuarios = 'Usuarios'
        Bajas    = 'Bajas'
        Grupos   = 'Grupos'
    }
    GrupoEmpleados = 'G-Empleados'
    PrefijoGrupo   = 'G-'
    GruposAdicionales = @{
        'G-LinuxAdmins' = @{
            Descripcion = 'Administradores del nodo RHEL (sudo via sssd)'
            Miembros    = @('jgarcia')
        }
        'G-ProxyUsers' = @{
            Descripcion = 'Usuarios con salida a internet por el proxy Squid'
            Miembros    = @('amenendez', 'jgarcia')
        }
    }
    HomesRuta      = 'C:\Homes'
    HomesRecurso   = 'Homes'
    GpoBaseline    = 'LAB-Baseline'
    Dhcp = @{
        Ambito            = 'Red del laboratorio'
        RangoInicio       = '192.168.56.100'
        RangoFin          = '192.168.56.149'
        Mascara           = '255.255.255.0'
        PuertaEnlace      = '192.168.56.1'
        DuracionConcesion = '0.08:00:00'
        Reserva = @{
            Nombre = 'impresora-oficina'
            IP     = '192.168.56.120'
            MAC    = '08-00-27-AA-BB-CC'
        }
    }
}

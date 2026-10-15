// ont-root-helper: started by the app through the administrator authorization
// dialog (AuthorizationExecuteWithPrivileges), which only sets the effective
// UID to 0. It makes the process fully root (pppd and bash both look at the
// real UID) and runs the broker script, keeping stdin/stdout connected to the
// app's private pipe.

#include <stdio.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "uso: ont-root-helper <script> [argomenti...]\n");
        return 2;
    }
    if (geteuid() != 0 || setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "ont-root-helper: privilegi di root non disponibili\n");
        return 2;
    }
    argv[0] = "/bin/bash";
    execv("/bin/bash", argv);
    perror("ont-root-helper: execv");
    return 2;
}

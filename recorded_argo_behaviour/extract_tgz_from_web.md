# Recorded Events:

## openat:
### Flags:
O_CREAT|O_RDWR|O_CLOEXEC|O_F_CREATED

### Command:
argoexec

## mkdirat:
### Flags:
N/A

### Command:
runc:[1:CHILD]

# Notes:
openat is called in the normal layer, mkdirat is called in the upper layer that is placed upon the normal layer.
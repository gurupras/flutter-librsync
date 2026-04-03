module github.com/gurupras/flutter-librsync

go 1.21

require github.com/balena-os/librsync-go v0.0.0-00010101000000-000000000000

require (
	github.com/balena-os/circbuf v0.1.3 // indirect
	golang.org/x/crypto v0.7.0 // indirect
	golang.org/x/sys v0.6.0 // indirect
)

replace github.com/balena-os/librsync-go => github.com/gurupras/librsync-go v0.9.0-gurupras-2

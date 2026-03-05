# # 10s hold after images; videos freeze last frame for 10s
# PMPVHOLDFOR=10 pmpv ~/pets

# # External monitor (index 1), fullscreen, 50% video speed
# PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=50 PMPVHOLDFOR=10 pmpv ~/pets

# source ~/igor_app/igor_slept_here/chatmpv.sh
# alias pmgo='PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=50 PMPVHOLDFOR=180 pmpv'

# source ~/igor_app/igor_slept_here/chatmpvex.sh
# alias pmxgo='PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=50 PMPVHOLDFOR=20 pmpvex'
# alias pmx5='PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=80 PMPVHOLDFOR=5 pmpvex'
# alias pmx10='PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=80 PMPVHOLDFOR=10 pmpvex'

source ~/igor_app/igor_slept_here/gem_mpv.sh
alias gemx10='PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=80 PMPVHOLDFOR=10 gem_mpv'
alias gemx='PMPVSCREEN=1 PMPVFS=1 PMPVVIDSPEED=60 gem_mpv_ex'
alias lodge='gemx ~/00/out/igor/clip/lodge/film'
alias cityx='gemx ~/00/out/igorx/aaa/film'
alias lodgex='gemx ~/00/out/igorx/clip/lodge/film'

# Kills all mpv instances and any stray bash loops from your MVP
alias kmpv='pkill -9 mpv; pkill -f "pmpv.*loop.sh"'
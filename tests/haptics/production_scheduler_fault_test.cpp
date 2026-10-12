#include "../../kit/host/sdl/haptic_drain_scheduler.h"
#include <cassert>
#include <cstdint>
#include <functional>
#include <iostream>
#include <vector>
// Fault-injection driver uses the *production* scheduler; fake engine/player
// callbacks are deterministic and do not pretend to be Apple's Core Haptics.
struct Harness {
 HapticDrainScheduler scheduler;
 bool running=false,player=false,interrupted=false;
 uint64_t epoch=0,player_epoch=0;
 int applied=0,updates=0,starts=0,stops=0;
 std::function<void()> fault;
 void publish(int x){scheduler.publish(static_cast<uint16_t>(x),0);}
 void reset(){++epoch;running=false;player=false;applied=0;}
 void stop_engine(){++epoch;running=false;player=false;applied=0;}
 void drain(){
  bool again;
  do{
   auto snapshot=scheduler.latest();
   int intensity=snapshot.intensity;
   if(fault){auto f=std::move(fault);fault=nullptr;f();}
   if(interrupted){player=false;running=false;applied=0;}
   else if(!intensity){if(player)++stops;player=false;applied=0;}
   else if(!player){
    auto before=epoch;
    running=true;++starts;
    if(before==epoch && scheduler.current(snapshot)){player=true;player_epoch=epoch;applied=intensity;}
   } else {
    auto before=epoch;++updates;
    if(before==epoch && player_epoch==epoch && scheduler.current(snapshot))applied=intensity;
   }
   again=scheduler.next(snapshot);
  }while(again);
 }
};
int main(){
 {Harness h;h.publish(100);h.fault=[&]{h.publish(0);};h.drain();assert(h.applied==0&&!h.player);}
 {Harness h;h.publish(100);h.fault=[&]{h.reset();};h.drain();assert(h.applied==100&&h.player);}
 {Harness h;h.publish(100);h.drain();h.publish(200);h.fault=[&]{h.stop_engine();h.publish(0);};h.drain();assert(h.applied==0&&!h.player);}
 {Harness h;h.publish(100);h.drain();h.interrupted=true;h.publish(200);h.drain();assert(h.applied==0);h.interrupted=false;h.publish(300);h.drain();assert(h.applied==300);}
 {Harness h;h.publish(100);h.drain();h.publish(200);h.fault=[&]{h.publish(0);};h.drain();assert(h.applied==0);}
 {Harness h;for(int i=1;i<=10000;++i)h.publish(i);h.publish(0);h.drain();assert(h.applied==0);}
 std::cout<<"PASS 6 production-scheduler fault-injection scenarios (mock framework)\n";
}

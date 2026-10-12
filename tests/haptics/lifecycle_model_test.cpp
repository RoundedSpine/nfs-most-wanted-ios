#include <cassert>
#include <cstdint>
#include <deque>
#include <functional>
#include <iostream>
#include <vector>
// Deterministic model of asynchronous engine/player sequencing.
// This intentionally does NOT exercise Apple's framework or production bridge.
struct Model {
 enum State { Stopped, Starting, Running, Suspended };
 State state=Stopped;
 uint64_t request=0,epoch=0,start_epoch=0,start_request=0;
 int intensity=0,played=0,creations=0,stale=0;
 std::deque<std::function<void()>> queue;
 void demand(int x) {
  intensity=x; ++request;
  if(state==Suspended)return;
  queue.push_back([this,v=request] {
   if(v!=request){++stale;return;}
   if(!intensity){played=0;return;}
   if(state==Running){played=intensity;return;}
   if(state==Starting)return;
   state=Starting;start_epoch=epoch;start_request=v;
  });
 }
 void reset(){++epoch;state=Stopped;played=0;}
 void stop(){++epoch;state=Stopped;played=0;}
 void suspend(){++epoch;state=Suspended;played=0;}
 void resume(){state=Stopped;}
 void complete_start(bool success){
  if(state!=Starting || start_epoch!=epoch){++stale;return;}
  state=success?Running:Stopped;
  if(success && intensity && start_request==request){played=intensity;++creations;}
  else if(success && intensity){played=intensity;++creations;}
 }
 void drain(){while(!queue.empty()){auto f=std::move(queue.front());queue.pop_front();f();}}
};
int main(){
 {Model m;m.demand(20);m.demand(80);m.demand(40);m.drain();m.complete_start(true);assert(m.played==40&&m.stale==2);}
 {Model m;m.demand(100);m.drain();m.demand(0);m.drain();m.complete_start(true);assert(m.played==0);}
 {Model m;m.demand(100);m.drain();m.reset();m.complete_start(true);assert(m.played==0&&m.creations==0);}
 {Model m;m.demand(100);m.drain();m.stop();m.complete_start(true);assert(m.played==0);}
 {Model m;m.demand(100);m.drain();m.complete_start(false);assert(m.state==Model::Stopped);}
 {Model m;m.demand(100);m.drain();m.complete_start(true);m.reset();assert(m.played==0);m.demand(50);m.drain();m.complete_start(true);assert(m.played==50);}
 {Model m;m.demand(100);m.drain();m.suspend();m.complete_start(true);m.demand(50);m.drain();assert(m.played==0);m.resume();m.demand(50);m.drain();m.complete_start(true);assert(m.played==50);}
 {Model m;for(int i=1;i<=10000;++i)m.demand(i%101);m.drain();assert(m.stale==9999);}
 std::cout<<"PASS 8 deterministic lifecycle model scenarios (NOT production Core Haptics)\n";
}

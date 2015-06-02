/'
 ' FROST x86 microkernel
 ' Copyright (C) 2010-2015  Stefan Schmidt
 ' 
 ' This program is free software: you can redistribute it and/or modify
 ' it under the terms of the GNU General Public License as published by
 ' the Free Software Foundation, either version 3 of the License, or
 ' (at your option) any later version.
 ' 
 ' This program is distributed in the hope that it will be useful,
 ' but WITHOUT ANY WARRANTY; without even the implied warranty of
 ' MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 ' GNU General Public License for more details.
 ' 
 ' You should have received a copy of the GNU General Public License
 ' along with this program.  If not, see <http://www.gnu.org/licenses/>.
 '/

#include "thread.bi"
#include "process.bi"
#include "pmm.bi"
#include "vmm.bi"
#include "kmm.bi"
#include "mem.bi"
#include "panic.bi"
#include "video.bi"
#include "modules.bi"

'' linked list of running threads
dim shared running_threads_list as list_head
dim shared current_thread as thread_type ptr = nullptr
dim shared idle_thread as thread_type ptr

operator thread_type.new (size as uinteger) as any ptr
	return kmalloc(size)
	'' constructor is called automatically
end operator

operator thread_type.delete (buffer as any ptr)
	kfree(buffer)
	'' destructor is called automatically
end operator

constructor thread_type (process as process_type ptr, entry as any ptr, userstack_pages as uinteger, flags as ubyte = 0)
	'' assign id
	this.id = process->get_tid()
	
	'' set owning process
	this.parent_process = process
	
	'' set flags
	this.flags = flags
	
	'' set state
	this.state = THREAD_STATE_DISABLED
	
	'' insert it into the list of the process
	process->thread_list.insert_before(@this.process_threads)
	
	'' reserve space for the user-stack
	'' FIXME: this always only reserves one page!
	this.userstack_p = pmm_alloc()
	
	'' allocate a memory area for the stack
	this.stack_area = process->a_s.allocate_area(1)
	this.userstack_bottom = stack_area->address
	
	'' map the area
	vmm_map_page(@process->context, this.stack_area->address, this.userstack_p, VMM_FLAGS.USER_DATA)
	
	'' reserve space for the kernel-stack
	this.kernelstack_p = pmm_alloc()
	
	'' map the kernel stack into the kernel's address space (unreachable from userspace)
	this.kernelstack_bottom = vmm_kernel_automap(this.kernelstack_p, PAGE_SIZE)
	
	'' create a pointer to the isf
	dim isf as interrupt_stack_frame ptr = this.kernelstack_bottom + PAGE_SIZE - sizeof(interrupt_stack_frame)
	this.isf = isf
	
	'' clear the whole structure
	memset(isf, 0, sizeof(interrupt_stack_frame))
	
	'' initialize the isf
	isf->eflags = &h0202
	isf->eip = cuint(entry)
	isf->esp = cuint(this.userstack_bottom) + PAGE_SIZE
	isf->cs = &h18 or &h03
	isf->ss = &h20 or &h03
end constructor

sub thread_type.destroy ()
	if (current_thread = @this) then
		this.state = THREAD_STATE_KILL_ON_SCHEDULE
		this.flags or= THREAD_FLAG_RESCHEDULE
		return
	end if

	'' remove thread from the active thread list
	this.deactivate()
	
	'' remove thread from the threadlist of the process
	process_remove_thread(@this)
	
	'' unmap kernelstack
	vmm_unmap_range(@this.parent_process->context, this.kernelstack_bottom, 1)
	
	'' free kernelstack
	pmm_free(this.kernelstack_p)
	
	vmm_unmap_range(@this.parent_process->context, this.stack_area->address, this.stack_area->pages)
	'' FIXME: free all pages of the stack
	pmm_free(this.userstack_p)
	delete this.stack_area
	
	'' free thread structure
	kfree(@this)
end sub

sub thread_type.activate ()
	if (this.state = THREAD_STATE_RUNNING) then
		panic_error("Kernel tried to activate an already activated thread!")
	end if
	
	'' set the state
	this.state = THREAD_STATE_RUNNING
	
	'' insert it into the running-thread-list
	running_threads_list.insert_before(@this.active_threads)
end sub

sub thread_type.deactivate ()
	this.state = THREAD_STATE_DISABLED
	
	this.active_threads.remove()
end sub

function schedule (isf as interrupt_stack_frame ptr) as thread_type ptr
	dim new_thread as thread_type ptr = current_thread
	
	dim it as list_head ptr = iif(current_thread, @current_thread->active_threads, @running_threads_list)
	while (not running_threads_list.is_empty())
		it = it->get_next()
		if (it = @running_threads_list) then continue while
		
		dim t as thread_type ptr = LIST_GET_ENTRY(it, thread_type, active_threads)
		
		if (t->state = THREAD_STATE_KILL_ON_SCHEDULE) then
			t->destroy()
			continue while
		end if
		
		new_thread = t
		exit while
	wend
	
	if (running_threads_list.is_empty()) then
		new_thread = idle_thread
	end if
	
	if (current_thread <> nullptr) then
		if (new_thread->parent_process <> current_thread->parent_process) then
			'' IO bitmaps are process-wide, so unload the bitmap on process switch
			tss_ptr->io_bitmap_offset = TSS_IO_BITMAP_NOT_LOADED
		end if
	end if
	
	current_thread = new_thread
	
	return new_thread
end function

sub thread_switch (isf as interrupt_stack_frame ptr)
	dim old_process as process_type ptr = nullptr
	if (get_current_thread() <> nullptr) then
		old_process = get_current_thread()->parent_process
	end if
	
	dim new_thread as thread_type ptr = schedule(isf)  '' select a new thread
	
	'' set his esp0 in the tss
	tss_ptr->esp0 = cuint(new_thread->isf) + sizeof(interrupt_stack_frame)
	
	'' load the new pagedir
	if ((new_thread->parent_process <> old_process) and (new_thread <> idle_thread)) then
		vmm_activate_context(@new_thread->parent_process->context)
	end if
end sub

function get_current_thread () as thread_type ptr
	return current_thread
end function

sub thread_idle ()
	do
		asm hlt
	loop
end sub

sub thread_create_idle_thread ()
	idle_thread = new thread_type(init_process, @thread_idle, 0)
	idle_thread->isf->cs = &h08
	idle_thread->isf->ss = &h10
	
	'' don't use thread_activate here, it's not a normal thread
	idle_thread->state = THREAD_STATE_RUNNING
end sub

sub set_io_bitmap ()
	tss_ptr->io_bitmap_offset = TSS_IO_BITMAP_OFFSET
	
	if (current_thread->parent_process->io_bitmap <> nullptr) then
		memcpy(@tss_ptr->io_bitmap(0), current_thread->parent_process->io_bitmap, &hFFFF\8)
	else
		memset(@tss_ptr->io_bitmap(0), &hFF, &hFFFF\8)
	end if
end sub
